//! Google Cast discovery.
//!
//! A Cast receiver answers `GET http://<host>:8008/setup/eureka_info` with its
//! identity. Probing that is cheap, needs no multicast, and returns the same
//! `ssdp_udn` the mDNS path would - so the device id a client sees is identical
//! whichever way the device was found.
//!
//! **Candidates come from three sources, not one.** The neighbour table alone
//! would miss a receiver that has gone quiet and been evicted from it, which is
//! a real case rather than a theoretical one:
//!
//! 1. hosts the DLNA scan just found - a TV that is both DLNA and Cast is the
//!    common case, and SSDP finds it reliably,
//! 2. the IPv4 neighbour table, for a Cast-only device,
//! 3. hosts a previous scan found, so a device that is briefly unresponsive
//!    does not disappear from the picker.
//!
//! mDNS is deliberately not used. It is the Python implementation's primary
//! path, so this is a real reduction in coverage: a Cast device that is absent
//! from the neighbour table *and* not visible to SSDP would be found by Flask
//! and missed here.

use serde::Serialize;
use std::collections::BTreeSet;
use std::net::Ipv4Addr;
use std::time::Duration;

/// How long a single eureka probe may take. Matches the Python original.
const PROBE_TIMEOUT: Duration = Duration::from_millis(600);

/// Ceiling on concurrent probes, matching the Python original.
const MAX_CONCURRENCY: usize = 20;

#[derive(Debug, Clone, Serialize)]
pub struct CastDevice {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub model: String,
    pub host: String,
    pub uuid: String,
}

/// IPv4 neighbours, so we do not shell out to `arp -a` as the Python does.
#[cfg(windows)]
pub fn neighbour_table() -> Vec<Ipv4Addr> {
    use std::mem::size_of;
    use windows_sys::Win32::NetworkManagement::IpHelper::{GetIpNetTable, MIB_IPNETTABLE, MIB_IPNETROW_LH};

    const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
    const MAX_PHYS_ADDR_LEN: u32 = 6;

    unsafe {
        let mut size: u32 = 0;
        // First call always fails, and tells us how much to allocate.
        let rc = GetIpNetTable(std::ptr::null_mut(), &mut size, 0);
        if size == 0 || (rc != 0 && rc != ERROR_INSUFFICIENT_BUFFER) {
            return Vec::new();
        }
        let mut buf = vec![0u8; size as usize];
        let table = buf.as_mut_ptr() as *mut MIB_IPNETTABLE;
        if GetIpNetTable(table, &mut size, 0) != 0 {
            return Vec::new();
        }
        let count = (*table).dwNumEntries as usize;
        let row_size = size_of::<MIB_IPNETROW_LH>();
        let rows = (*table).table.as_ptr();

        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            let row = &*rows.add(i);
            // A row with no resolved hardware address is an incomplete entry.
            if row.dwPhysAddrLen != MAX_PHYS_ADDR_LEN || row.dwAddr == 0 {
                continue;
            }
            let addr = Ipv4Addr::from(u32::from_le(row.dwAddr));
            if addr.is_loopback()
                || addr.is_unspecified()
                || addr.is_multicast()
                || addr.is_broadcast()
                || addr.is_link_local()
            {
                continue;
            }
            let _ = row_size;
            out.push(addr);
        }
        out
    }
}

#[cfg(not(windows))]
pub fn neighbour_table() -> Vec<Ipv4Addr> {
    Vec::new()
}

/// Hosts to probe: DLNA hosts, cached Cast hosts, and the neighbour table.
pub fn candidate_hosts(
    dlna_hosts: &[String],
    cached_hosts: &[String],
    neighbours: &[Ipv4Addr],
) -> Vec<String> {
    let mut set: BTreeSet<String> = BTreeSet::new();
    for h in dlna_hosts.iter().chain(cached_hosts.iter()) {
        if let Some(clean) = normalise(h) {
            set.insert(clean);
        }
    }
    for n in neighbours {
        set.insert(n.to_string());
    }
    set.into_iter().collect()
}

/// A host string that is a plain, routable IPv4 address on the LAN.
fn normalise(host: &str) -> Option<String> {
    let trimmed = host.trim().trim_matches(['[', ']']);
    let addr: Ipv4Addr = trimmed.parse().ok()?;
    if addr.is_loopback()
        || addr.is_unspecified()
        || addr.is_multicast()
        || addr.is_broadcast()
        // Link-local (169.254/16) cannot carry a Cast receiver, and probing it
        // just costs a timeout. The Python original filtered this by prefix.
        || addr.is_link_local()
    {
        return None;
    }
    Some(addr.to_string())
}

/// Probe candidates for the eureka endpoint and return what answered.
///
/// Bounded concurrency: a residential network's neighbour table can be large,
/// and a serial probe at 600 ms each would add minutes to a scan.
pub async fn discover(hosts: Vec<String>) -> Result<Vec<CastDevice>, String> {
    if hosts.is_empty() {
        return Ok(Vec::new());
    }
    let client = reqwest::Client::builder()
        .timeout(PROBE_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())?;

    let semaphore = std::sync::Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENCY));
    let mut tasks = Vec::with_capacity(hosts.len());
    for host in hosts {
        let client = client.clone();
        let semaphore = semaphore.clone();
        tasks.push(tokio::spawn(async move {
            let _permit = semaphore.acquire_owned().await.ok()?;
            probe_one(&client, &host).await
        }));
    }

    let mut found: Vec<CastDevice> = Vec::new();
    for task in tasks {
        if let Ok(Some(device)) = task.await {
            found.push(device);
        }
    }
    found.sort_by(|a, b| a.id.cmp(&b.id));
    found.dedup_by(|a, b| a.id == b.id);
    Ok(found)
}

async fn probe_one(client: &reqwest::Client, host: &str) -> Option<CastDevice> {
    let url = format!("http://{}:8008/setup/eureka_info", host);
    let response = client.get(&url).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: serde_json::Value = response.json().await.ok()?;

    // `ssdp_udn` is what mDNS would report as the uuid, so the device id a
    // client stores is the same whichever discovery path found it.
    let udn = body
        .get("ssdp_udn")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| body.get("bssid").and_then(|v| v.as_str()))
        .unwrap_or(host)
        .to_string();
    let name = body
        .get("name")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("Cast device")
        .to_string();

    Some(CastDevice {
        id: format!("cast:{}", udn),
        kind: "cast".into(),
        name,
        model: "Chromecast".into(),
        host: host.to_string(),
        uuid: udn,
    })
}

/// A Cast receiver that shares a host with a DLNA renderer reports only
/// "Chromecast"; the renderer's model name is more useful on screen.
pub fn enrich_model_from_dlna(device: &mut CastDevice, dlna: &[(String, String)]) {
    if device.model != "Chromecast" {
        return;
    }
    for (host, model) in dlna {
        if host == &device.host && !model.is_empty() {
            device.model = format!("Chromecast ({})", model);
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_union_three_sources() {
        let hosts = candidate_hosts(
            &["192.168.1.8".to_string()],
            &["192.168.1.44".to_string()],
            &[Ipv4Addr::new(192, 168, 1, 70), Ipv4Addr::new(192, 168, 1, 8)],
        );
        assert!(hosts.contains(&"192.168.1.8".to_string()), "DLNA host");
        assert!(hosts.contains(&"192.168.1.44".to_string()), "cached host");
        assert!(hosts.contains(&"192.168.1.70".to_string()), "neighbour");
        assert_eq!(hosts.len(), 3, "duplicates collapse: {:?}", hosts);
    }

    #[test]
    fn unroutable_candidates_are_dropped() {
        let hosts = candidate_hosts(
            &[
                "127.0.0.1".into(),
                "0.0.0.0".into(),
                "169.254.1.1".into(),
                "not-an-ip".into(),
                " 192.168.1.8 ".into(),
            ],
            &[],
            &[],
        );
        assert_eq!(hosts, vec!["192.168.1.8".to_string()]);
    }

    #[test]
    fn the_neighbour_table_yields_this_hosts_lan() {
        // Not asserting a specific address - the point is that the FFI works
        // and returns routable IPv4 only.
        let entries = neighbour_table();
        for addr in &entries {
            assert!(!addr.is_loopback(), "{}", addr);
            assert!(!addr.is_multicast(), "{}", addr);
        }
    }

    #[test]
    fn model_is_enriched_from_a_dlna_host_on_the_same_address() {
        let mut d = CastDevice {
            id: "cast:abc".into(),
            kind: "cast".into(),
            name: "TV".into(),
            model: "Chromecast".into(),
            host: "192.168.1.8".into(),
            uuid: "abc".into(),
        };
        enrich_model_from_dlna(
            &mut d,
            &[("192.168.1.8".to_string(), "UA43DU7000KLXL".to_string())],
        );
        assert_eq!(d.model, "Chromecast (UA43DU7000KLXL)");
    }

    #[test]
    fn a_different_host_does_not_lose_its_model() {
        let mut d = CastDevice {
            id: "cast:abc".into(),
            kind: "cast".into(),
            name: "Stick".into(),
            model: "Chromecast".into(),
            host: "192.168.1.50".into(),
            uuid: "abc".into(),
        };
        enrich_model_from_dlna(
            &mut d,
            &[("192.168.1.8".to_string(), "UA43DU7000KLXL".to_string())],
        );
        assert_eq!(d.model, "Chromecast", "a model from another host would be a lie");
    }

    #[tokio::test]
    async fn probing_nothing_is_not_an_error() {
        let found = discover(Vec::new()).await.expect("empty probe set");
        assert!(found.is_empty());
    }
}