import Foundation

/// What a copied text looks like when it is a credential. Clipboard history never keeps such text, and Phone
/// never sends it; a copy that its app marks as concealed is skipped without looking at it.
///
/// The checks run in order: keys with a known shape (a provider's prefix, a private key block, a token
/// format), a name that says what follows (`API_KEY=…`, `"password": "…"`), then a lone word that reads like
/// a password or a random key. Skipping a little too much costs one item of history; too little keeps a key.
/// All of it runs on this Mac and nothing about it is recorded.
enum ClipboardSecret: Sendable, Equatable {
    case apiKey, token, privateKey, password, credentials

    /// A credential is short. Of a longer text only the start is read, which keeps a copied log from
    /// holding up the next copy.
    static let scanLimit = 64 * 1024

    static func detect(_ text: String) -> ClipboardSecret? {
        let scanned = text.utf8.count > scanLimit ? String(text.prefix(scanLimit)) : text
        let range = NSRange(scanned.startIndex..., in: scanned)
        for (kind, pattern) in shapes where pattern.firstMatch(in: scanned, range: range) != nil { return kind }
        if let kind = named(in: scanned, range: range) { return kind }
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace) {
            if looksLikePassword(trimmed) { return .password }
            return looksLikeKey(trimmed) ? .token : nil
        }
        // A short message that hands over a key: "here it is: 8hQ…".
        guard trimmed.utf8.count <= 1_024 else { return nil }
        return trimmed.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;:!?")) }
            .contains(where: looksLikeKey) ? .token : nil
    }

    // MARK: Known shapes

    /// Keys and tokens whose format gives them away. A prefix only counts at the start of a word.
    private static let shapes = compile([
        (.privateKey, [
            #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
            #"PuTTY-User-Key-File-\d+:"#,
            #"AGE-SECRET-KEY-1[0-9A-Z]{58}"#,
        ]),
        (.apiKey, [
            // AI providers
            #"sk-ant-[A-Za-z0-9_-]{20,}"#,                      // Anthropic
            #"sk-(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{20,}"#,      // OpenAI, OpenRouter, DeepSeek, Langfuse and more
            #"AIza[0-9A-Za-z_-]{35}"#,                          // Google
            #"GOCSPX-[A-Za-z0-9_-]{20,}"#,                      // Google OAuth client secret
            #"(?:hf|api_org)_[A-Za-z0-9]{30,}"#,                // Hugging Face
            #"gsk_[A-Za-z0-9]{40,}"#,                           // Groq
            #"xai-[A-Za-z0-9]{40,}"#,                           // xAI
            #"pplx-[A-Za-z0-9]{40,}"#,                          // Perplexity
            #"r8_[A-Za-z0-9]{30,}"#,                            // Replicate
            #"fw_[A-Za-z0-9]{20,}"#,                            // Fireworks
            #"sk_[a-f0-9]{48}"#,                                // ElevenLabs
            #"csk-[a-z0-9]{40,}"#,                              // Cerebras
            #"pcsk_[A-Za-z0-9_]{40,}"#,                         // Pinecone
            #"lsv2_(?:pt|sk)_[a-f0-9]{32}_[a-f0-9]{10}"#,       // LangSmith
            #"tvly-(?:dev-)?[A-Za-z0-9]{20,}"#,                 // Tavily
            #"fc-[a-f0-9]{32}"#,                                // Firecrawl
            // Clouds and developer services
            #"(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}"#,            // AWS access key ID
            #"[A-Za-z0-9_~.]{3}\dQ~[A-Za-z0-9_~.-]{31,34}"#,    // Azure client secret
            #"(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}"#,       // Stripe
            #"whsec_[A-Za-z0-9+/=]{20,}"#,                      // Stripe webhook secret
            #"sq0(?:atp|csp)-[A-Za-z0-9_-]{22,}"#,              // Square
            #"SG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{40,}"#,     // SendGrid
            #"SK[0-9a-fA-F]{32}"#,                              // Twilio
            #"key-[0-9a-f]{32}"#,                               // Mailgun
            #"[0-9a-f]{32}-us\d{1,2}"#,                         // Mailchimp
            #"shp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}"#,             // Shopify
            #"do[opr]_v1_[a-f0-9]{64}"#,                        // DigitalOcean
            #"v1\.0-[a-f0-9]{24}-[a-f0-9]{146}"#,               // Cloudflare origin CA
            #"nfp_[A-Za-z0-9]{36,}"#,                           // Netlify
            #"sb(?:p|_secret)_[A-Za-z0-9_]{30,}"#,              // Supabase
            #"pscale_(?:tkn|pw|oauth)_[A-Za-z0-9_.-]{32,}"#,    // PlanetScale
            #"rnd_[A-Za-z0-9]{32,}"#,                           // Render
            #"pul-[a-f0-9]{40}"#,                               // Pulumi
            #"NRAK-[A-Z0-9]{27}"#,                              // New Relic
            #"glsa_[A-Za-z0-9]{32}_[A-Fa-f0-9]{8}"#,            // Grafana service account
            #"glc_[A-Za-z0-9+/]{32,}={0,2}"#,                   // Grafana Cloud
            #"sntr[ysu]_[A-Za-z0-9+/=_]{40,}"#,                 // Sentry
            #"lin_(?:api|oauth)_[A-Za-z0-9]{32,}"#,             // Linear
            #"(?:secret|ntn)_[A-Za-z0-9]{40,}"#,                // Notion
            #"fig[dpu]_[A-Za-z0-9_-]{30,}"#,                    // Figma
            #"pat[A-Za-z0-9]{14}\.[a-f0-9]{64}"#,               // Airtable
            #"PMAK-[a-f0-9]{24}-[a-f0-9]{34}"#,                 // Postman
            #"CFPAT-[A-Za-z0-9_-]{43}"#,                        // Contentful
            #"AAAA[A-Za-z0-9_-]{7}:[A-Za-z0-9_-]{140}"#,        // Firebase Cloud Messaging
            #"ATATT3[A-Za-z0-9_=-]{50,}"#,                      // Atlassian
            #"bb_live_[A-Za-z0-9_-]{20,}"#,                     // Browserbase
            #"A3-[A-Z0-9]{6}-[A-Z0-9]{5,6}-(?:[A-Z0-9]{5}-){3}[A-Z0-9]{5}"#, // 1Password secret key
        ]),
        (.token, [
            #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}"#,       // GitHub
            #"github_pat_[A-Za-z0-9_]{50,}"#,
            #"gl(?:pat|ptt|dt|rt|cbt|imt|soat|ft|oas|wt)-[A-Za-z0-9_-]{20,}"#, // GitLab
            #"npm_[A-Za-z0-9]{36}"#,
            #"pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{50,}"#,
            #"dckr_pat_[A-Za-z0-9_-]{20,}"#,                    // Docker Hub
            #"rubygems_[a-f0-9]{48}"#,
            #"oy2[a-z0-9]{43}"#,                                // NuGet
            #"hv[sbr]\.[A-Za-z0-9_-]{24,}"#,                    // HashiCorp Vault
            #"[A-Za-z0-9]{14}\.atlasv1\.[A-Za-z0-9_=-]{60,}"#,  // Terraform Cloud
            #"dp\.(?:pt|st|sa|ct|scim|audit)\.[A-Za-z0-9]{40,}"#, // Doppler
            #"ops_eyJ[A-Za-z0-9+/=_-]{50,}"#,                   // 1Password service account
            #"xox[abposre]-[A-Za-z0-9-]{10,}"#,                 // Slack
            #"xapp-\d-[A-Za-z0-9-]{10,}"#,
            #"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]{20,}"#,
            #"https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{20,}"#,
            #"[MNO][A-Za-z\d_-]{23,27}\.[A-Za-z\d_-]{6}\.[A-Za-z\d_-]{27,40}"#, // Discord bot
            #"\d{8,10}:AA[A-Za-z0-9_-]{33}"#,                   // Telegram bot
            #"ya29\.[0-9A-Za-z_-]{20,}"#,                       // Google OAuth access token
            #"1//0[0-9A-Za-z_-]{30,}"#,                         // Google OAuth refresh token
            #"sl\.[A-Za-z0-9_-]{130,}"#,                        // Dropbox
            #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, // JSON Web Token
            #"(?i:bearer)\s+[A-Za-z0-9._~+/-]{20,}=*"#,
        ]),
        (.credentials, [
            // A password inside an address: postgres://user:password@host, https://user:token@github.com.
            #"[A-Za-z][A-Za-z0-9+.-]{1,20}://[^\s:/@]{1,256}:[^\s/@]{3,256}@[^\s/]+"#,
            #"(?i:authorization):\s*(?i:basic|bearer|token|digest)\s+\S{8,}"#,
            #"(?:AccountKey|SharedAccessKey)=[A-Za-z0-9+/]{40,}={0,2}"#, // Azure connection string
        ]),
    ])

    private static func compile(_ groups: [(ClipboardSecret, [String])]) -> [(ClipboardSecret, NSRegularExpression)] {
        groups.map { kind, patterns in
            // A prefix inside a longer word, such as "task-…" for "sk-", is not one.
            let joined = patterns.map { "(?:\($0))" }.joined(separator: "|")
            return (kind, try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])(?:\(joined))"))
        }
    }

    // MARK: Named values

    /// `API_KEY=…`, `"password": "…"`, `X-Api-Key: …`, `Passwort: …`: a name that says what follows. What
    /// comes after the word is set off, as in `token_type`, so that `tokenizer` and `passwordHash` are not one.
    private static let assignment = try! NSRegularExpression(pattern:
        #"(?i)(?<![A-Za-z0-9])["']?([A-Za-z0-9_.-]{0,40}?(?:password|passwd|passphrase|passwort|kennwort|pwd|secret|secret[_.-]?key|token|api[_.-]?key|access[_.-]?key|private[_.-]?key|auth[_.-]?key|client[_.-]?secret|credentials?)(?:[_.-][A-Za-z0-9_.-]{0,40})?)["']?[ \t]*(?::=|=>|[:=])[ \t]*(?:"([^"\n]{1,256})"|'([^'\n]{1,256})'|([^\s"',;)\]}]{1,256}))"#)

    /// A value that only stands in for one: `${TOKEN}`, `<your-key>`, `xxx`, `null`, or the name again.
    private static let placeholder = try! NSRegularExpression(pattern:
        #"(?i)^(?:\$|<|\{\{|%\(|\[|your[_ -]|xxx|\*\*\*|•|redacted|placeholder|example|changeme$|none$|null$|nil$|undefined$|true$|false$|required$|optional$|password$|passwort$|kennwort$|secret$|token$|api[_ -]?key$)"#)

    /// Code that names where a value comes from rather than the value: `config.apiKey`, `getToken()`,
    /// `OPENAI_API_KEY`, a path.
    private static let reference = try! NSRegularExpression(pattern:
        #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$|^[A-Za-z_][A-Za-z0-9_.]*\(|^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$|^(?:/|~/|\./|\.\./)"#)

    private static func named(in text: String, range: NSRange) -> ClipboardSecret? {
        for match in assignment.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = text[nameRange].lowercased()
            let quoted = (2...3).lazy.compactMap { Range(match.range(at: $0), in: text) }.first
            guard let valueRange = quoted ?? Range(match.range(at: 4), in: text) else { continue }
            let value = String(text[valueRange])
            let password = ["pass", "pwd", "kennwort"].contains { name.contains($0) }
            guard !value.contains(where: \.isWhitespace), value.count >= (password ? 4 : 8),
                  !matches(placeholder, value), !matches(reference, value) else { continue }
            // A quoted password may be any word. Anything else needs what a key has: a digit or a symbol, or
            // the length and mixed case of a random one, so that `token: optional` stays a setting.
            if !(password && quoted != nil) {
                let marked = value.contains(where: { $0.isNumber || isSymbol($0) })
                let random = value.count >= 16 && value.contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
                guard marked || random, password || !value.allSatisfy(\.isNumber) else { continue }
            }
            return password ? .password : name.contains("token") ? .token : .apiKey
        }
        return nil
    }

    // MARK: One word alone

    /// Addresses, paths, numbers, dates, hashes and code: one word that is not a secret.
    private static let ordinaryWord = try! NSRegularExpression(pattern: [
        #"^[A-Za-z][A-Za-z0-9+.-]*://"#,                                  // a link without a password in it
        #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#,                              // an email address
        #"^(?:/|~|\./|\.\./)"#,                                           // a path
        #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, // a UUID
        #"^[0-9a-f]+$|^[0-9A-F]+$"#,                                      // a commit or a checksum
        #"^#[0-9a-fA-F]{3,8}$"#,                                          // a colour
        #"^[#@][A-Za-z0-9_]+$"#,                                          // a hashtag or a handle
        #"^[\d.,:;+\-/%()$€£¥]+$"#,                                       // a number, a date, an amount
        #"^\d{1,2}:\d{2}(?::\d{2})?(?:am|pm|AM|PM)?$"#,                  // a time of day
        #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#,                          // a domain or a version
        #"\.(?:[a-z]{2,4}|[A-Z]{2,4})$"#,                                 // a file name
        #"\d{4}-\d{2}-\d{2}"#,                                            // something dated
        #"^\$\{?[A-Za-z_]"#,                                              // a shell variable
        #"^<[^>]*>"#,                                                     // markup
        #"^="#,                                                           // a spreadsheet formula
        #"^[A-Za-z]+\d+,\d+$"#,                                           // a Mac or iPhone model, MacBookPro18,3
        #"^[A-Za-z_$][A-Za-z0-9_.$]*[(\[<{]"#,                            // a call, an index, a generic
    ].joined(separator: "|"))

    /// A password on its own: 8 to 64 characters, with upper and lower case, digits and a symbol such as
    /// `!` or `#`. `-`, `_` and `.` do not count, since names of files and things use them.
    static func looksLikePassword(_ word: String) -> Bool {
        guard (8...64).contains(word.count), !matches(ordinaryWord, word) else { return false }
        return word.contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
            && word.contains(where: \.isNumber) && word.contains(where: isSymbol)
    }

    /// A random key without a label: long, mixed, digits spread through it. Names of things put their
    /// digits at the end, so `ClipboardHistoryControllerTests2` stays readable.
    static func looksLikeKey(_ word: String) -> Bool {
        guard (24...512).contains(word.count), !matches(ordinaryWord, word),
              word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-+/=.~".contains($0)) }),
              word.contains(where: \.isUppercase), word.contains(where: \.isLowercase) else { return false }
        let digits = word.filter(\.isNumber).count
        let digitRuns = word.split(whereSeparator: { !$0.isNumber }).count
        return digits >= 4 && digitRuns >= 2 && entropy(word) >= 3.8
    }

    /// Bits per character: a random key has about 5, a word about 3.
    static func entropy(_ word: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in word { counts[character, default: 0] += 1 }
        let length = Double(word.count)
        return counts.values.reduce(0) { total, count in
            let share = Double(count) / length
            return total - share * log2(share)
        }
    }

    private static func isSymbol(_ character: Character) -> Bool {
        character.isASCII && !character.isLetter && !character.isNumber && !character.isWhitespace && !"-_.".contains(character)
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
