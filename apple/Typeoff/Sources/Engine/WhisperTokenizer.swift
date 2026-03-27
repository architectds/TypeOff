import Foundation

/// Whisper BPE tokenizer — decodes token IDs to text.
/// Loads vocab.json (bundled in app) for ID → string mapping.
///
/// Special tokens:
///   SOT (50258), EOT (50257), Transcribe (50359), Translate (50358)
///   Language tokens: en (50259), zh (50260), es (50262), etc.
final class WhisperTokenizer {

    // Special token IDs
    static let sot: Int32 = 50258           // <|startoftranscript|>
    static let eot: Int32 = 50257           // <|endoftranscript|>
    static let transcribe: Int32 = 50359    // <|transcribe|>
    static let translate: Int32 = 50358     // <|translate|>
    static let noSpeech: Int32 = 50362      // <|nospeech|>
    static let noTimestamps: Int32 = 50363  // <|notimestamps|>

    // Language tokens (50259 = en, 50260 = zh, etc.)
    static let languageTokenBase: Int32 = 50259

    static let languages: [String: Int32] = [
        "en": 50259, "zh": 50260, "de": 50261, "es": 50262, "ru": 50263,
        "ko": 50264, "fr": 50265, "ja": 50266, "pt": 50267, "tr": 50268,
        "pl": 50269, "nl": 50271, "ar": 50272, "it": 50274,
    ]

    private var idToToken: [Int32: String] = [:]
    private var isLoaded = false

    // Byte decoder: maps Whisper's byte-level tokens back to UTF-8
    private let byteDecoder: [Character: UInt8]

    init() {
        // Build byte decoder (reverse of GPT-2 byte encoder)
        var decoder: [Character: UInt8] = [:]
        var byteList: [UInt8] = []

        // Printable ASCII ranges
        for b in UInt8(33)...UInt8(126) { byteList.append(b) }  // ! to ~
        for b in UInt8(161)...UInt8(172) { byteList.append(b) }  // ¡ to ¬
        for b in UInt8(174)...UInt8(255) { byteList.append(b) }  // ® to ÿ

        var n = 0
        for b: UInt8 in 0...255 {
            if !byteList.contains(b) {
                byteList.append(b)
                decoder[Character(Unicode.Scalar(256 + n))] = b
                n += 1
            }
        }

        // Map the printable bytes
        for b in byteList.prefix(byteList.count - n) {
            decoder[Character(Unicode.Scalar(b))] = b
        }

        byteDecoder = decoder
    }

    /// Load vocab.json from app bundle.
    func load() {
        guard !isLoaded else { return }

        guard let url = Bundle.main.url(forResource: "vocab", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let vocab = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            print("[Typeoff] Failed to load vocab.json")
            return
        }

        // Invert: token string → ID becomes ID → token string
        for (token, id) in vocab {
            idToToken[Int32(id)] = token
        }

        isLoaded = true
        print("[Typeoff] Tokenizer loaded: \(idToToken.count) tokens")
    }

    /// Decode token IDs to text string.
    func decode(_ tokenIds: [Int32]) -> String {
        var bytes: [UInt8] = []

        for id in tokenIds {
            // Skip special tokens
            if id >= WhisperTokenizer.eot { continue }

            guard let token = idToToken[id] else { continue }

            // Convert each character through byte decoder
            for char in token {
                if let byte = byteDecoder[char] {
                    bytes.append(byte)
                } else {
                    // Fallback: try direct ASCII
                    if let ascii = char.asciiValue {
                        bytes.append(ascii)
                    }
                }
            }
        }

        // Whisper uses Ġ prefix for space (maps to 0x20 via byte decoder)
        return String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Get initial token sequence for transcription.
    func initialTokens(language: String? = nil) -> [Int32] {
        var tokens: [Int32] = [WhisperTokenizer.sot]

        if let lang = language, let langToken = WhisperTokenizer.languages[lang] {
            tokens.append(langToken)
        }

        tokens.append(WhisperTokenizer.transcribe)
        tokens.append(WhisperTokenizer.noTimestamps)

        return tokens
    }
}
