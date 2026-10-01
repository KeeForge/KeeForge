import Foundation

/// RFC 4180 CSV reader for password-manager export files.
///
/// Works on Unicode scalars rather than `Character`s: Swift folds `"\r\n"`
/// into one grapheme, which would hide a record break inside a quoted field's
/// line ending.
enum CSVReader {
    struct Record: Sendable, Equatable {
        var fields: [String]
        /// A stray quote inside an unquoted field, or text after a closing
        /// quote. The fields are kept verbatim, but their boundaries cannot be
        /// trusted.
        var isMalformed: Bool
    }

    enum ReadError: Error, Equatable {
        /// A quoted field never closes, so every later row would be read as
        /// part of it. Nothing after the opening quote can be trusted.
        case unterminatedQuotedField(recordIndex: Int)
    }

    /// Reads every record in `text`. Empty lines are not records; a leading
    /// byte-order mark is ignored.
    static func records(in text: String) throws -> [Record] {
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let carriageReturn: Unicode.Scalar = "\r"
        let lineFeed: Unicode.Scalar = "\n"

        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" {
            scalars.removeFirst()
        }

        var records: [Record] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var isInQuotes = false
        var fieldWasQuoted = false
        var isAfterClosingQuote = false
        var isMalformed = false

        func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
            isAfterClosingQuote = false
        }

        func endRecord() {
            let isBlankLine = fields.isEmpty && field.isEmpty && fieldWasQuoted == false
            if isBlankLine == false {
                endField()
                records.append(Record(fields: fields, isMalformed: isMalformed))
            }
            fields = []
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
            isAfterClosingQuote = false
            isMalformed = false
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil

            if isInQuotes {
                if scalar == quote {
                    if next == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        isInQuotes = false
                        isAfterClosingQuote = true
                    }
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case comma:
                    endField()
                case carriageReturn, lineFeed:
                    endRecord()
                    if scalar == carriageReturn, next == lineFeed {
                        index += 1
                    }
                case quote where field.isEmpty && fieldWasQuoted == false:
                    isInQuotes = true
                    fieldWasQuoted = true
                default:
                    if scalar == quote || isAfterClosingQuote {
                        isMalformed = true
                    }
                    field.append(scalar)
                }
            }
            index += 1
        }

        if isInQuotes {
            throw ReadError.unterminatedQuotedField(recordIndex: records.count)
        }
        endRecord()
        return records
    }
}
