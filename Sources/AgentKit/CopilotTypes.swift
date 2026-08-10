import CaptureKit
import Foundation
import ProviderKit

/// The live-copilot actions exposed to the app shell. `catchUp` is intentionally
/// part of the shared vocabulary even though it is never a classifier result:
/// it is initiated only by an explicit user request.
public enum CopilotAction: String, Codable, Sendable, Equatable, CaseIterable {
    case suggestAnswer = "suggest_answer"
    case catchUp = "catch_up"
    case flagCommitment = "flag_commitment"
}

/// One finalized conversational turn at AgentKit's boundary. This deliberately
/// mirrors only the stable transcript facts the copilot needs, so AppShell can
/// bridge TranscribeKit's turn stream without giving the agent a store handle.
public struct CopilotTurn: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var source: AudioSource
    public var text: String
    public var segmentIDs: [UUID]
    public var tStart: TimeInterval
    public var tEnd: TimeInterval

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        text: String,
        segmentIDs: [UUID] = [],
        tStart: TimeInterval,
        tEnd: TimeInterval
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.segmentIDs = segmentIDs
        self.tStart = tStart
        self.tEnd = tEnd
    }
}

/// Per-meeting values snapshotted by AppShell. The settings layer owns named
/// sensitivity presets; AgentKit accepts their numeric threshold so policy is
/// deterministic and independently testable.
public struct CopilotConfiguration: Sendable, Equatable {
    public var aiFeaturesEnabled: Bool
    public var proactiveEnabled: Bool
    public var confidenceThreshold: Double
    public var preferredName: String?
    public var cooldownSeconds: TimeInterval

    public init(
        aiFeaturesEnabled: Bool = true,
        proactiveEnabled: Bool = true,
        confidenceThreshold: Double = 0.90,
        preferredName: String? = nil,
        cooldownSeconds: TimeInterval = 45
    ) {
        self.aiFeaturesEnabled = aiFeaturesEnabled
        self.proactiveEnabled = proactiveEnabled
        self.confidenceThreshold = min(max(confidenceThreshold, 0), 1)
        let name = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredName = name.flatMap { $0.isEmpty ? nil : $0 }
        self.cooldownSeconds = max(0, cooldownSeconds)
    }
}

/// The classifier's strict JSON value. A JSON action of `"none"` maps to a
/// nil `action`; `catch_up` is rejected at decode time so it cannot leak into
/// the proactive path even when a provider ignores the response schema.
public struct ClassifierDecision: Codable, Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable {
        case invalidAction(String)
        case invalidConfidence(Double)
        case targetRequired
        case targetMustBeNull
    }

    public var action: CopilotAction?
    public var confidence: Double
    public var target: String?

    public init(action: CopilotAction?, confidence: Double, target: String?) throws {
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw ValidationError.invalidConfidence(confidence)
        }
        if action == .catchUp { throw ValidationError.invalidAction(CopilotAction.catchUp.rawValue) }

        let normalizedTarget = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == nil {
            guard normalizedTarget == nil else { throw ValidationError.targetMustBeNull }
        } else {
            guard let normalizedTarget, !normalizedTarget.isEmpty else {
                throw ValidationError.targetRequired
            }
        }
        self.action = action
        self.confidence = confidence
        self.target = normalizedTarget
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case confidence
        case target
    }

    public init(from decoder: any Decoder) throws {
        let dynamicContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowedKeys: Set<String> = [
            CodingKeys.action.rawValue,
            CodingKeys.confidence.rawValue,
            CodingKeys.target.rawValue,
        ]
        let unknownKeys = Set(dynamicContainer.allKeys.map(\.stringValue)).subtracting(allowedKeys)
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown classifier keys: \(unknownKeys.sorted())"
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAction = try container.decode(String.self, forKey: .action)
        let action: CopilotAction?
        switch rawAction {
        case "none": action = nil
        case CopilotAction.suggestAnswer.rawValue: action = .suggestAnswer
        case CopilotAction.flagCommitment.rawValue: action = .flagCommitment
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "invalid proactive action: \(rawAction)"
            )
        }
        guard container.contains(.target) else {
            throw DecodingError.keyNotFound(
                CodingKeys.target,
                .init(codingPath: container.codingPath, debugDescription: "target is required")
            )
        }
        let confidence = try container.decode(Double.self, forKey: .confidence)
        let target = try container.decodeIfPresent(String.self, forKey: .target)
        do {
            try self.init(action: action, confidence: confidence, target: target)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action?.rawValue ?? "none", forKey: .action)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(target, forKey: .target)
    }

    /// Whether this otherwise-valid decision clears the selected sensitivity.
    public func meetsThreshold(_ threshold: Double) -> Bool {
        action != nil && confidence >= min(max(threshold, 0), 1)
    }
}

extension ClassifierDecision {
    static let responseFormat = ResponseFormat(
        name: "copilot_classifier_decision",
        schema: try! JSONSchema([
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["none", CopilotAction.suggestAnswer.rawValue,
                             CopilotAction.flagCommitment.rawValue],
                ],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "target": ["type": ["string", "null"]],
            ],
            "required": ["action", "confidence", "target"],
            "additionalProperties": false,
        ])
    )
}

public struct CopilotGateState: Sendable, Equatable {
    public var userSpeaking: Bool
    public var hasActiveProactiveCard: Bool
    public var lastProactiveAt: Date?

    public init(
        userSpeaking: Bool = false,
        hasActiveProactiveCard: Bool = false,
        lastProactiveAt: Date? = nil
    ) {
        self.userSpeaking = userSpeaking
        self.hasActiveProactiveCard = hasActiveProactiveCard
        self.lastProactiveAt = lastProactiveAt
    }
}

public enum CopilotGateRejection: Sendable, Equatable {
    case aiDisabled
    case proactiveDisabled
    case userSource
    case userSpeaking
    case activeCard
    case cooldown
    case trivialTurn
}

public enum CopilotGateResult: Sendable, Equatable {
    case allowed
    case rejected(CopilotGateRejection)
}

/// Pure local gates. Their order is stable so diagnostics and tests get one
/// unambiguous rejection even when several conditions apply.
public enum CopilotGate {
    public static func evaluate(
        turn: CopilotTurn,
        configuration: CopilotConfiguration,
        state: CopilotGateState,
        now: Date
    ) -> CopilotGateResult {
        guard configuration.aiFeaturesEnabled else { return .rejected(.aiDisabled) }
        guard configuration.proactiveEnabled else { return .rejected(.proactiveDisabled) }
        guard turn.source == .system else { return .rejected(.userSource) }
        guard !state.userSpeaking else { return .rejected(.userSpeaking) }
        guard !state.hasActiveProactiveCard else { return .rejected(.activeCard) }
        if let lastProactiveAt = state.lastProactiveAt,
           now.timeIntervalSince(lastProactiveAt) < configuration.cooldownSeconds
        {
            return .rejected(.cooldown)
        }
        guard !isTrivial(turn.text) else { return .rejected(.trivialTurn) }
        return .allowed
    }

    /// Reject pure acknowledgements/noise while allowing genuinely useful
    /// short questions such as "Thoughts?" or "Why?" through to the model.
    public static func isTrivial(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .alphanumerics) != nil
        else { return true }
        return [
            "uh", "um", "hmm", "mm", "mhm", "okay", "ok", "yeah", "yep",
            "yes", "no", "right", "thanks", "thank you",
        ].contains(normalized)
    }
}
