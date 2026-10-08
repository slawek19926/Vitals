import Foundation

public enum CSV {
    public struct ParseError: LocalizedError {
        public let line: Int
        public let reason: String
        public var errorDescription: String? { "CSV line \(line): \(reason)" }
    }

    /// RFC 4180 quoting, UTF-8 BOM, CRLF and multiline cells.
    public static func parse(_ text: String) throws -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first?.value == 0xFEFF { scalars.removeFirst() }
        var rows: [[String]] = [], row: [String] = []
        var field = "", quoted = false, closed = false, touched = false
        var index = 0, line = 1
        func finishField() {
            row.append(field); field = ""; closed = false
        }
        func finishRow() {
            finishField(); rows.append(row); row = []; touched = false
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if quoted {
                if scalar.value == 34 {
                    if index + 1 < scalars.count, scalars[index + 1].value == 34 {
                        field.append("\""); index += 1
                    } else { quoted = false; closed = true }
                } else {
                    field.unicodeScalars.append(scalar)
                    if scalar.value == 10 { line += 1 }
                }
            } else {
                switch scalar.value {
                case 34:
                    guard field.isEmpty, !closed else { throw ParseError(line: line, reason: "unexpected quote") }
                    quoted = true; touched = true
                case 44: finishField(); touched = true
                case 10, 13:
                    finishRow(); line += 1
                    if scalar.value == 13, index + 1 < scalars.count, scalars[index + 1].value == 10 { index += 1 }
                default:
                    guard !closed else { throw ParseError(line: line, reason: "characters after a closing quote") }
                    field.unicodeScalars.append(scalar); touched = true
                }
            }
            index += 1
        }
        guard !quoted else { throw ParseError(line: line, reason: "unclosed quoted cell") }
        if touched || !field.isEmpty || !row.isEmpty || closed { finishRow() }
        return rows
    }

    public static func encode(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                let boundarySpace = cell.first?.isWhitespace == true || cell.last?.isWhitespace == true
                if boundarySpace || cell.contains(",") || cell.contains("\"") || cell.contains("\r") || cell.contains("\n") {
                    return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return cell
            }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }
}
