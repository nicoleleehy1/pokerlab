import SwiftUI
import SwiftData
import PokerCourse
import CloudKit
import CoreTransferable
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("fourColorDeck") private var fourColorDeck = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Query(sort: \DrillAttempt.date) private var attempts: [DrillAttempt]
    @Query(sort: \AnswerLogEntry.day) private var answerLog: [AnswerLogEntry]
    @State private var syncStatus = "Checking…"

    var body: some View {
        Form {
            Section {
                Toggle("Four-colour deck", isOn: $fourColorDeck)
                    .accessibilityIdentifier("four-color-toggle")
                HStack(spacing: 6) {
                    ForEach(["As", "Kh", "Qd", "Jc"], id: \.self) { CardView(card: .init($0), baseWidth: 34) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(differentiateWithoutColor
                     ? "Four colours are on because Differentiate Without Color is enabled in Accessibility settings."
                     : "Diamonds blue and clubs green. Suit symbols are always shown too.")
            }
            Section("iCloud sync") {
                LabeledContent("Status", value: syncStatus)
            }
            Section("Data") {
                ShareLink(item: CSVExport(attempts: attempts.map(CSVExport.Row.init)), preview: SharePreview("PokerLab history.csv")) {
                    Label("Export history (CSV)", systemImage: "square.and.arrow.up")
                }
                LabeledContent("Spots answered", value: "\(attempts.count)")
                ShareLink(item: AnswerLogExport(events: answerLog.compactMap(\.event)), preview: SharePreview("PokerLab answer log.csv")) {
                    Label("Export course answer log (CSV)", systemImage: "square.and.arrow.up")
                }
            }
            Section("About") {
                LabeledContent("Engine", value: "PokerCore (Swift 6)")
                Link("Source and benchmarks", destination: URL(string: "https://github.com/")!)
            }
        }
        .navigationTitle("Settings")
        .task { syncStatus = await Self.cloudStatus() }
    }

    static func cloudStatus() async -> String {
        guard let id = AppConfig.cloudKitContainerID else { return "Off: CloudKit container not configured" }
        do {
            switch try await CKContainer(identifier: id).accountStatus() {
            case .available: return "On"
            case .noAccount: return "Sign in to iCloud to sync"
            case .restricted: return "Restricted on this device"
            case .temporarilyUnavailable: return "Temporarily unavailable"
            case .couldNotDetermine: return "Unknown"
            @unknown default: return "Unknown"
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

/// Training history as a CSV file for the share sheet.
struct CSVExport: Transferable {
    struct Row: Sendable {
        let date: Date, category: String, spot: String, answer: Double, truth: Double, correct: Bool, points: Int
        @MainActor init(_ a: DrillAttempt) {
            date = a.date; category = a.categoryRaw; spot = a.spotSummary
            answer = a.userAnswer; truth = a.correctAnswer; correct = a.isCorrect; points = a.points
        }
    }
    let attempts: [Row]

    var csv: String {
        let header = "date,category,spot,answer,truth,correct,points"
        let iso = ISO8601DateFormatter()
        let rows = attempts.map {
            "\(iso.string(from: $0.date)),\($0.category),\"\($0.spot.replacingOccurrences(of: "\"", with: "'"))\",\($0.answer),\($0.truth),\($0.correct),\($0.points)"
        }
        return ([header] + rows).joined(separator: "\n")
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.csv.utf8) }
            .suggestedFileName("PokerLab history.csv")
    }
}
