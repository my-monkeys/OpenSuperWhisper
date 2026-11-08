import Foundation

/// A `multipart/form-data` body: text fields and files, written by hand because URLSession
/// builds none. Lines end in CRLF, as the format requires.
struct MultipartForm {
    struct File: Equatable {
        let name: String
        let filename: String
        let contentType: String
        let data: Data
    }

    var boundary = "osw-" + UUID().uuidString
    var fields: [(name: String, value: String)] = []
    var files: [File] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    var body: Data {
        var body = Data()
        for field in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            body.append(field.value)
            body.append("\r\n")
        }
        for file in files {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
            body.append("Content-Type: \(file.contentType)\r\n\r\n")
            body.append(file.data)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ text: String) {
        append(Data(text.utf8))
    }
}
