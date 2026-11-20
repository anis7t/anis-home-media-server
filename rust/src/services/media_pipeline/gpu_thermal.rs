//! Fail-closed thermal admission using HWiNFO Shared Memory v2.
//!
//! Sensor labels are configured by substring because HWiNFO device labels vary
//! between driver and firmware versions. Missing, stale, malformed, or ambiguous
//! sensor data never authorizes dual-adapter work.

use std::time::{SystemTime, UNIX_EPOCH};

#[cfg_attr(not(windows), allow(dead_code))]
const HEADER_MIN: usize = 64;
const MAX_SHARED_BYTES: usize = 16 * 1024 * 1024;
const MAX_AGE_SECS: i64 = 15;

#[derive(Debug, Clone, PartialEq)]
pub struct GpuTemperatures {
    pub rx560x_c: f64,
    pub vega8_c: f64,
    pub age_secs: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ThermalStatus {
    Safe(GpuTemperatures),
    Unsafe(String),
}

fn u32_at(data: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        data.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

fn i64_at(data: &[u8], offset: usize) -> Option<i64> {
    Some(i64::from_le_bytes(
        data.get(offset..offset + 8)?.try_into().ok()?,
    ))
}

fn c_string(data: &[u8], offset: usize, len: usize) -> Option<String> {
    let raw = data.get(offset..offset + len)?;
    let end = raw.iter().position(|b| *b == 0).unwrap_or(raw.len());
    Some(String::from_utf8_lossy(&raw[..end]).trim().to_string())
}

#[derive(Debug, Clone, Copy)]
struct Header {
    poll_time: i64,
    sensor_offset: usize,
    sensor_size: usize,
    sensor_count: usize,
    reading_offset: usize,
    reading_size: usize,
    reading_count: usize,
}

fn parse_header(data: &[u8]) -> Option<Header> {
    // The HWiNFO FOURCC is `SiWH` as a little-endian integer, so its bytes in
    // the shared mapping are `HWiS`.
    if data.get(..4)? != b"HWiS" {
        return None;
    }
    // HWiNFO Shared Memory v2 stores Unix epoch seconds at 0x0C, followed by
    // the section descriptors at 0x14.
    let poll_time = i64_at(data, 12)?;
    let d = 20;
    let sensor_offset = u32_at(data, d)? as usize;
    let sensor_size = u32_at(data, d + 4)? as usize;
    let sensor_count = u32_at(data, d + 8)? as usize;
    let reading_offset = u32_at(data, d + 12)? as usize;
    let reading_size = u32_at(data, d + 16)? as usize;
    let reading_count = u32_at(data, d + 20)? as usize;
    let sensor_end = sensor_offset.checked_add(sensor_size.checked_mul(sensor_count)?)?;
    let reading_end = reading_offset.checked_add(reading_size.checked_mul(reading_count)?)?;
    if (200..=4096).contains(&sensor_size)
        && (200..=8192).contains(&reading_size)
        && sensor_count <= 50_000
        && reading_count <= 500_000
        && sensor_end <= MAX_SHARED_BYTES
        && reading_end <= MAX_SHARED_BYTES
    {
        return Some(Header {
            poll_time,
            sensor_offset,
            sensor_size,
            sensor_count,
            reading_offset,
            reading_size,
            reading_count,
        });
    }
    None
}

fn mapped_bytes() -> Option<Vec<u8>> {
    #[cfg(windows)]
    unsafe {
        use std::ffi::c_void;
        type Handle = *mut c_void;
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn OpenFileMappingW(access: u32, inherit: i32, name: *const u16) -> Handle;
            fn MapViewOfFile(
                handle: Handle,
                access: u32,
                high: u32,
                low: u32,
                bytes: usize,
            ) -> *mut c_void;
            fn UnmapViewOfFile(address: *const c_void) -> i32;
            fn CloseHandle(handle: Handle) -> i32;
        }
        const FILE_MAP_READ: u32 = 0x0004;
        for name in [
            "Global\\HWiNFO_SENS_SM2",
            "Local\\HWiNFO_SENS_SM2",
            "HWiNFO_SENS_SM2",
        ] {
            let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
            let handle = OpenFileMappingW(FILE_MAP_READ, 0, wide.as_ptr());
            if handle.is_null() {
                continue;
            }
            let head = MapViewOfFile(handle, FILE_MAP_READ, 0, 0, HEADER_MIN);
            if head.is_null() {
                CloseHandle(handle);
                continue;
            }
            let first = std::slice::from_raw_parts(head.cast::<u8>(), HEADER_MIN).to_vec();
            UnmapViewOfFile(head);
            let Some(h) = parse_header(&first) else {
                CloseHandle(handle);
                continue;
            };
            let length = h.sensor_offset + h.sensor_size * h.sensor_count;
            let length = length.max(h.reading_offset + h.reading_size * h.reading_count);
            if length > MAX_SHARED_BYTES {
                CloseHandle(handle);
                continue;
            }
            let view = MapViewOfFile(handle, FILE_MAP_READ, 0, 0, length);
            if view.is_null() {
                CloseHandle(handle);
                continue;
            }
            let bytes = std::slice::from_raw_parts(view.cast::<u8>(), length).to_vec();
            UnmapViewOfFile(view);
            CloseHandle(handle);
            return Some(bytes);
        }
    }
    #[cfg(not(windows))]
    {}
    #[allow(unreachable_code)]
    None
}

fn current_hw_time() -> Option<i64> {
    Some(SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64)
}

fn configured_match(key: &str, fallback: &str) -> String {
    std::env::var(key)
        .unwrap_or_else(|_| fallback.to_string())
        .to_lowercase()
}

pub fn read_temperatures() -> ThermalStatus {
    let Some(bytes) = mapped_bytes() else {
        return ThermalStatus::Unsafe("HWiNFO shared-memory mapping is unavailable".into());
    };
    let Some(header) = parse_header(&bytes) else {
        return ThermalStatus::Unsafe("HWiNFO shared-memory header is invalid".into());
    };
    let Some(now) = current_hw_time() else {
        return ThermalStatus::Unsafe("System clock is unavailable".into());
    };
    let age = now.saturating_sub(header.poll_time);
    if !(0..=MAX_AGE_SECS).contains(&age) {
        return ThermalStatus::Unsafe(format!("HWiNFO readings are stale ({age}s old)"));
    }

    let rx_match = configured_match("MEDIA_SERVER_GPU_TEMP_RX_MATCH", "560X");
    let vega_match = configured_match("MEDIA_SERVER_GPU_TEMP_VEGA_MATCH", "Vega 8");
    let mut groups = Vec::with_capacity(header.sensor_count);
    for index in 0..header.sensor_count {
        let base = header.sensor_offset + index * header.sensor_size;
        let original = c_string(&bytes, base + 8, 128).unwrap_or_default();
        let user = c_string(&bytes, base + 136, 128).unwrap_or_default();
        groups.push(if user.is_empty() { original } else { user });
    }

    let mut rx = Vec::new();
    let mut vega = Vec::new();
    for index in 0..header.reading_count {
        let base = header.reading_offset + index * header.reading_size;
        if u32_at(&bytes, base) != Some(1) {
            continue;
        } // temperature reading
        let sensor_idx = u32_at(&bytes, base + 4).unwrap_or(u32::MAX) as usize;
        let Some(group) = groups.get(sensor_idx) else {
            continue;
        };
        let original = c_string(&bytes, base + 12, 128).unwrap_or_default();
        let user = c_string(&bytes, base + 140, 128).unwrap_or_default();
        let label = if user.is_empty() { original } else { user };
        let unit = c_string(&bytes, base + 268, 16).unwrap_or_default();
        let unit = unit.to_ascii_lowercase();
        if !unit.contains('c') || unit.contains('f') {
            continue;
        }
        // Value is at 0x11C in both HWiNFO shared-memory layouts. v2 appends
        // UTF-8 copies after the legacy fields, so deriving this from the
        // record tail points into those copies instead of the temperature.
        let value_offset = base + 0x11C;
        let Some(value) = bytes
            .get(value_offset..value_offset + 8)
            .and_then(|v| <[u8; 8]>::try_from(v).ok())
            .map(f64::from_le_bytes)
        else {
            continue;
        };
        if !value.is_finite() || !(0.0..=125.0).contains(&value) {
            continue;
        }
        let group_low = group.to_lowercase();
        let label_low = label.to_lowercase();
        let is_gpu_temp = label_low.contains("temperature")
            || label_low.contains("gpu temp")
            || label_low.contains("hot spot")
            || label_low.contains("hotspot");
        if !is_gpu_temp {
            continue;
        }
        if group_low.contains(&rx_match) {
            rx.push(value);
        }
        if group_low.contains(&vega_match) {
            vega.push(value);
        }
    }

    // Use the hottest matching sensor for each adapter; duplicates are acceptable,
    // but no matching sensor is a hard stop.
    match (
        rx.into_iter().reduce(f64::max),
        vega.into_iter().reduce(f64::max),
    ) {
        (Some(rx560x_c), Some(vega8_c)) => ThermalStatus::Safe(GpuTemperatures {
            rx560x_c,
            vega8_c,
            age_secs: age,
        }),
        _ => ThermalStatus::Unsafe(
            "Configured RX 560X or Vega 8 temperature sensor was not found".into(),
        ),
    }
}

pub fn dual_gpu_thermal_safe() -> bool {
    match read_temperatures() {
        ThermalStatus::Safe(t) => {
            let limit = std::env::var("MEDIA_SERVER_GPU_MAX_TEMP_C")
                .ok()
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or(85.0);
            let safe = t.rx560x_c < limit && t.vega8_c < limit;
            if !safe {
                tracing::warn!(
                    rx_temp_c = t.rx560x_c,
                    vega_temp_c = t.vega8_c,
                    limit_c = limit,
                    "Dual-GPU admission blocked by temperature"
                );
            }
            safe
        }
        ThermalStatus::Unsafe(reason) => {
            tracing::warn!(%reason, "Dual-GPU admission blocked: thermal telemetry unavailable");
            false
        }
    }
}

pub fn adapter_temperature_safe(is_discrete: bool) -> bool {
    let ThermalStatus::Safe(t) = read_temperatures() else {
        return false;
    };
    let limit = std::env::var("MEDIA_SERVER_GPU_MAX_TEMP_C")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(85.0);
    if is_discrete {
        t.rx560x_c < limit
    } else {
        t.vega8_c < limit
    }
}

pub fn critical_temperature_or_sensor_loss(is_discrete: bool) -> bool {
    let ThermalStatus::Safe(t) = read_temperatures() else {
        return true;
    };
    let critical = std::env::var("MEDIA_SERVER_GPU_CRITICAL_TEMP_C")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(92.0);
    if is_discrete {
        t.rx560x_c >= critical
    } else {
        t.vega8_c >= critical
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_header_is_rejected() {
        assert!(parse_header(&[0; HEADER_MIN]).is_none());
    }

    #[test]
    fn valid_header_parses_sections_and_counts() {
        let mut data = vec![0u8; HEADER_MIN];
        data[..4].copy_from_slice(b"HWiS");
        data[12..20].copy_from_slice(&1_800_000_000i64.to_le_bytes());
        // HWiNFO 8.61 reports the v2 element sizes: 392-byte sensors and
        // 460-byte readings, with the section descriptor beginning at 0x14.
        let values = [48u32, 392, 1, 440, 460, 2];
        for (i, value) in values.into_iter().enumerate() {
            data[20 + i * 4..24 + i * 4].copy_from_slice(&value.to_le_bytes());
        }
        let h = parse_header(&data).unwrap();
        assert_eq!(h.poll_time, 1_800_000_000);
        assert_eq!(h.sensor_size, 392);
        assert_eq!(h.reading_size, 460);
        assert_eq!(h.sensor_count, 1);
        assert_eq!(h.reading_count, 2);
    }

    #[test]
    #[ignore = "requires live HWiNFO shared memory and both Radeon GPU sensors"]
    fn live_shared_memory_reports_both_gpu_temperatures() {
        match read_temperatures() {
            ThermalStatus::Safe(t) => {
                assert!((0.0..=125.0).contains(&t.rx560x_c));
                assert!((0.0..=125.0).contains(&t.vega8_c));
                assert!((0..=MAX_AGE_SECS).contains(&t.age_secs));
                assert!(dual_gpu_thermal_safe(), "both GPUs should be below 85C");
                assert!(
                    adapter_temperature_safe(true),
                    "RX 560X should be below 85C"
                );
                assert!(
                    adapter_temperature_safe(false),
                    "Vega 8 should be below 85C"
                );
                assert!(!critical_temperature_or_sensor_loss(true));
                assert!(!critical_temperature_or_sensor_loss(false));
                println!(
                    "HWiNFO live GPU temperatures: RX 560X={:.1}C, Vega 8={:.1}C, age={}s",
                    t.rx560x_c, t.vega8_c, t.age_secs
                );
            }
            ThermalStatus::Unsafe(reason) => panic!("HWiNFO sensor check failed: {reason}"),
        }
    }
}
