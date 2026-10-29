use crate::error::AppError;
use axum::{
    body::Body,
    http::{header, HeaderMap, HeaderValue, Method, Response, StatusCode},
};
use std::path::PathBuf;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};
use tokio_util::io::ReaderStream;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRange {
    FromTo(u64, u64),
    From(u64),
    Suffix(u64),
}

impl HttpRange {
    pub fn parse(header: &str) -> Option<Self> {
        let spec = header.trim().strip_prefix("bytes=")?;
        let first = spec.split(',').next()?.trim();
        if let Some(suffix) = first.strip_prefix('-') {
            suffix.parse::<u64>().ok().map(HttpRange::Suffix)
        } else if let Some(idx) = first.find('-') {
            let start = first[..idx].trim().parse::<u64>().ok()?;
            let end_str = first[idx + 1..].trim();
            if end_str.is_empty() {
                Some(HttpRange::From(start))
            } else {
                let end = end_str.parse::<u64>().ok()?;
                Some(HttpRange::FromTo(start, end))
            }
        } else {
            None
        }
    }

    pub fn resolve(self, total: u64) -> Result<(u64, u64), ()> {
        if total == 0 {
            return Err(());
        }
        match self {
            HttpRange::FromTo(start, end) => {
                if start >= total || start > end {
                    Err(())
                } else {
                    Ok((start, end.min(total - 1)))
                }
            }
            HttpRange::From(start) => {
                if start >= total {
                    Err(())
                } else {
                    Ok((start, total - 1))
                }
            }
            HttpRange::Suffix(len) => {
                if len == 0 {
                    Err(())
                } else {
                    let len = len.min(total);
                    Ok((total - len, total - 1))
                }
            }
        }
    }
}

pub struct RangeService;

impl RangeService {
    pub async fn stream_file(
        path: PathBuf,
        headers: HeaderMap,
        method: Method,
    ) -> Result<Response<Body>, AppError> {
        let mut file = File::open(&path)
            .await
            .map_err(|e| AppError::NotFound(e.to_string()))?;
        let metadata = file
            .metadata()
            .await
            .map_err(|e| AppError::Internal(e.to_string()))?;
        let total_size = metadata.len();

        let mime = mime_guess::from_path(&path)
            .first_or_octet_stream()
            .as_ref()
            .to_string();

        let mut res_headers = HeaderMap::new();
        res_headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
        res_headers.insert(header::CONTENT_TYPE, HeaderValue::from_str(&mime).unwrap());
        res_headers.insert("access-control-allow-origin", HeaderValue::from_static("*"));
        res_headers.insert(
            "access-control-allow-methods",
            HeaderValue::from_static("GET, HEAD, OPTIONS"),
        );
        res_headers.insert(
            "access-control-allow-headers",
            HeaderValue::from_static("Range, Origin, Accept, Content-Type"),
        );
        res_headers.insert(
            "access-control-expose-headers",
            HeaderValue::from_static("Content-Length, Content-Range, Accept-Ranges"),
        );
        res_headers.insert(
            "cross-origin-resource-policy",
            HeaderValue::from_static("cross-origin"),
        );
        res_headers.insert(
            "contentfeatures.dlna.org",
            HeaderValue::from_static(
                "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000",
            ),
        );
        res_headers.insert(
            "transfermode.dlna.org",
            HeaderValue::from_static("Streaming"),
        );

        if let Some(range_raw) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
            if let Some(parsed) = HttpRange::parse(range_raw) {
                match parsed.resolve(total_size) {
                    Ok((start, end)) => {
                        let length = end - start + 1;
                        res_headers.insert(header::CONTENT_LENGTH, HeaderValue::from(length));
                        res_headers.insert(
                            header::CONTENT_RANGE,
                            HeaderValue::from_str(&format!(
                                "bytes {}-{}/{}",
                                start, end, total_size
                            ))
                            .unwrap(),
                        );

                        let body = if method == Method::HEAD {
                            Body::empty()
                        } else {
                            file.seek(SeekFrom::Start(start))
                                .await
                                .map_err(|e| AppError::Internal(e.to_string()))?;
                            let stream = ReaderStream::with_capacity(file.take(length), 64 * 1024);
                            Body::from_stream(stream)
                        };

                        let mut res = Response::new(body);
                        *res.status_mut() = StatusCode::PARTIAL_CONTENT;
                        *res.headers_mut() = res_headers;
                        return Ok(res);
                    }
                    Err(_) => {
                        res_headers.insert(
                            header::CONTENT_RANGE,
                            HeaderValue::from_str(&format!("bytes */{}", total_size)).unwrap(),
                        );
                        let mut res = Response::new(Body::empty());
                        *res.status_mut() = StatusCode::RANGE_NOT_SATISFIABLE;
                        *res.headers_mut() = res_headers;
                        return Ok(res);
                    }
                }
            }
        }

        // Full 200 response
        res_headers.insert(header::CONTENT_LENGTH, HeaderValue::from(total_size));
        let body = if method == Method::HEAD {
            Body::empty()
        } else {
            let stream = ReaderStream::with_capacity(file, 64 * 1024);
            Body::from_stream(stream)
        };

        let mut res = Response::new(body);
        *res.status_mut() = StatusCode::OK;
        *res.headers_mut() = res_headers;
        Ok(res)
    }
}
