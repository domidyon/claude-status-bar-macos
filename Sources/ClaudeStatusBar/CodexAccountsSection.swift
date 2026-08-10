import SwiftUI
import StatusBarCore

struct CodexAccountsSection: View {
    let accounts: [CodexAccount]
    let states: [String: CodexUsageState]
    let now: Date
    let onSwitch: (CodexAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex CLI").font(.caption).foregroundStyle(.secondary)
            if accounts.isEmpty {
                Text("No Codex login found").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    HStack(spacing: 6) {
                        Text(account.label).fontWeight(account.isActive ? .bold : .regular)
                        if account.isActive {
                            Text("active").font(.caption2).padding(.horizontal, 4)
                                .background(.tint.opacity(0.2), in: Capsule())
                        } else {
                            Button("Switch") { onSwitch(account) }.controlSize(.small)
                        }
                        Spacer()
                    }
                    if let snapshot = states[account.id]?.snapshot {
                        CodexUsageLine(window: snapshot.primary, now: now)
                        if let secondary = snapshot.secondary {
                            CodexUsageLine(window: secondary, now: now)
                        }
                    } else if states[account.id]?.unavailable == true {
                        Text("Usage unavailable").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Loading usage…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Switching affects new Codex CLI sessions.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CodexUsageLine: View {
    let window: CodexUsageWindow
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(durationLabel).font(.caption2.monospaced()).frame(width: 22, alignment: .leading)
            ProgressView(value: min(window.usedPercent, 100), total: 100).tint(color)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            if let resetsAt = window.resetsAt, resetsAt > now {
                Text("resets in \(MenuBarText.elapsed(resetsAt.timeIntervalSince(now)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var durationLabel: String {
        let hours = Int((window.duration / 3600).rounded())
        return hours >= 24 ? "\(hours / 24)d" : "\(hours)h"
    }

    private var color: Color {
        switch UsageLevel.level(for: window.usedPercent) {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}
