use std::io::{self, Read, Write};

pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
const REQUEST_MAGIC: &[u8; 4] = b"OCB1";
const RESPONSE_MAGIC: &[u8; 4] = b"OCR1";

#[derive(Debug, PartialEq, Eq)]
pub struct Request {
    pub id: u64,
    pub png: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Response {
    pub id: u64,
    pub result: Result<String, String>,
}

#[cfg(any(windows, test))]
pub fn write_request(mut writer: impl Write, request: &Request) -> io::Result<()> {
    if request.png.len() > MAX_IMAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "image exceeds 16 MiB",
        ));
    }
    writer.write_all(REQUEST_MAGIC)?;
    writer.write_all(&request.id.to_be_bytes())?;
    writer.write_all(&(request.png.len() as u32).to_be_bytes())?;
    writer.write_all(&request.png)?;
    writer.flush()
}

pub fn read_request(mut reader: impl Read) -> io::Result<Option<Request>> {
    let mut magic = [0; 4];
    match reader.read(&mut magic[..1])? {
        0 => return Ok(None),
        1 => reader.read_exact(&mut magic[1..])?,
        _ => unreachable!(),
    }
    if &magic != REQUEST_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid request magic",
        ));
    }
    let id = read_u64(&mut reader)?;
    let length = read_u32(&mut reader)? as usize;
    if length > MAX_IMAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "image exceeds 16 MiB",
        ));
    }
    let mut png = vec![0; length];
    reader.read_exact(&mut png)?;
    Ok(Some(Request { id, png }))
}

pub fn write_response(mut writer: impl Write, response: &Response) -> io::Result<()> {
    let (status, message) = match &response.result {
        Ok(path) => (0, path.as_bytes()),
        Err(error) => (1, error.as_bytes()),
    };
    if message.len() > 64 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "response exceeds 64 KiB",
        ));
    }
    let length = u32::try_from(message.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "response is too large"))?;
    writer.write_all(RESPONSE_MAGIC)?;
    writer.write_all(&response.id.to_be_bytes())?;
    writer.write_all(&[status])?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(message)?;
    writer.flush()
}

#[cfg(any(windows, test))]
pub fn read_response(mut reader: impl Read) -> io::Result<Response> {
    let mut magic = [0; 4];
    reader.read_exact(&mut magic)?;
    if &magic != RESPONSE_MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid response magic",
        ));
    }
    let id = read_u64(&mut reader)?;
    let mut status = [0];
    reader.read_exact(&mut status)?;
    let length = read_u32(&mut reader)? as usize;
    if length > 64 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "response exceeds 64 KiB",
        ));
    }
    let mut message = vec![0; length];
    reader.read_exact(&mut message)?;
    let message = String::from_utf8(message)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "response is not UTF-8"))?;
    Ok(Response {
        id,
        result: if status[0] == 0 {
            Ok(message)
        } else {
            Err(message)
        },
    })
}

fn read_u32(reader: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0; 4];
    reader.read_exact(&mut bytes)?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_u64(reader: &mut impl Read) -> io::Result<u64> {
    let mut bytes = [0; 8];
    reader.read_exact(&mut bytes)?;
    Ok(u64::from_be_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip() {
        let request = Request {
            id: 42,
            png: b"png".to_vec(),
        };
        let mut bytes = Vec::new();
        write_request(&mut bytes, &request).unwrap();
        assert_eq!(read_request(bytes.as_slice()).unwrap(), Some(request));
    }

    #[test]
    fn response_round_trip() {
        for response in [
            Response {
                id: 1,
                result: Ok("/tmp/image.png".into()),
            },
            Response {
                id: 2,
                result: Err("invalid image".into()),
            },
        ] {
            let mut bytes = Vec::new();
            write_response(&mut bytes, &response).unwrap();
            assert_eq!(read_response(bytes.as_slice()).unwrap(), response);
        }
    }

    #[test]
    fn rejects_oversized_request_before_allocating() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(REQUEST_MAGIC);
        bytes.extend_from_slice(&1_u64.to_be_bytes());
        bytes.extend_from_slice(&((MAX_IMAGE_BYTES + 1) as u32).to_be_bytes());
        assert_eq!(
            read_request(bytes.as_slice()).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn rejects_oversized_response() {
        let response = Response {
            id: 1,
            result: Err("x".repeat(64 * 1024 + 1)),
        };
        assert_eq!(
            write_response(Vec::new(), &response).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }
}
