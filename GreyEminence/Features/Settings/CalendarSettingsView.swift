import SwiftUI

struct CalendarSettingsView: View {
    @AppStorage("calendarIntegration") private var calendarIntegration = true
    @AppStorage(GraphConfig.enabledKey) private var graphEnabled = false
    @AppStorage(GraphConfig.clientIDDefaultsKey) private var graphClientID = ""
    @AppStorage(GraphConfig.unusedKey) private var graphUnused = true

    @State private var graphAuth = GraphAuthService.shared
    @State private var calendarService = CalendarService()
    @State private var allCalendars: [CalendarChoice] = []
    @State private var disabledIDs: Set<String> = CalendarSelection.disabledIDs()
    @State private var nearby: [CalendarService.NearbyPreview] = []
    @State private var refreshNote: String?

    private var eventKitCalendars: [CalendarChoice] {
        allCalendars.filter { $0.source == .eventKit }
    }
    private var graphCalendars: [CalendarChoice] {
        allCalendars.filter { $0.source == .microsoftGraph }
    }

    var body: some View {
        Form {
            // MARK: - Local (EventKit)
            Section {
                Toggle("Auto-detect calendar events", isOn: $calendarIntegration)
                    .helpTip(.settingsCalAutoDetect)
                Text("Reads calendars synced to macOS (Calendar app) to auto-name recordings and match attendees. Turning a calendar on here only includes it in matching — it is not a Microsoft login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(calendarService.accessStatusText)
                    .font(.caption)
                    .foregroundStyle(calendarService.authorizationState == .authorized ? Color.secondary : Color.orange)

                HStack {
                    Button("Request Calendar Access") {
                        Task { await reload() }
                    }
                    Button("Refresh calendars") {
                        Task { await reload() }
                    }
                }
                .controlSize(.small)

                if let refreshNote {
                    Text(refreshNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if eventKitCalendars.isEmpty {
                    Text("No macOS calendars detected. Add the Office 365 / Exchange account in System Settings → Internet Accounts (Calendars enabled). You do not need Microsoft Graph if that calendar already appears here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Group {
                        matchSubheader
                        calendarToggleList(eventKitCalendars)
                        nearbyEventsBlock
                    }
                }
            } header: {
                Label("On this Mac", systemImage: "menubar.dock.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            // MARK: - Microsoft 365 (Graph)
            Section {
                Toggle("I am not using Microsoft Graph", isOn: $graphUnused)
                Text("Leave this on if Outlook is already on this Mac. Graph is a separate Entra app login, not macOS Calendar and not Outlook.app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !graphUnused {
                    Group {
                        if graphAuth.isConnected {
                            connectedRows
                        } else {
                            disconnectedRows
                        }
                    }
                }
            } header: {
                Label("Microsoft 365 / Teams", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                Text("Optional. Pulls Outlook/Teams over the network when the work calendar is not synced to macOS. Read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        await calendarService.requestAccess()
        allCalendars = await calendarService.availableCalendars()
        disabledIDs = CalendarSelection.disabledIDs()
        nearby = calendarService.nearbyPreview()
        if calendarService.authorizationState != .authorized {
            refreshNote = calendarService.accessStatusText
        } else if eventKitCalendars.isEmpty {
            refreshNote = "Access granted, but EventKit sees 0 calendars. Check System Settings → Internet Accounts."
        } else if nearby.isEmpty {
            refreshNote = "\(eventKitCalendars.count) calendar(s) visible; no timed meetings in the next ±2 hours."
        } else {
            refreshNote = "\(eventKitCalendars.count) calendar(s), \(nearby.count) nearby meeting(s)."
        }
    }

    @ViewBuilder
    private var nearbyEventsBlock: some View {
        Text("Nearby meetings (macOS Calendar, ±2 hours)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        if nearby.isEmpty {
            Text("None in this window. If you have an Outlook meeting now, EventKit is not seeing that calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(nearby) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                    Text("\(event.calendarTitle) · \(event.account) · \(event.start.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isGraphClientReady: Bool {
        let typed = graphClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && !typed.hasPrefix("<") { return true }
        return GraphConfig.isConfigured
    }

    private func connectAndReload() {
        Task {
            await graphAuth.connect()
            await reload()
        }
    }

    // MARK: - Calendar selection rows

    private var matchSubheader: some View {
        Text("Match these calendars")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func calendarToggleList(_ choices: [CalendarChoice]) -> some View {
        ForEach(choices) { choice in
            Toggle(isOn: binding(for: choice)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                    Text(choice.account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(for choice: CalendarChoice) -> Binding<Bool> {
        Binding(
            get: { !disabledIDs.contains(choice.id) },
            set: { isOn in
                CalendarSelection.setEnabled(isOn, id: choice.id)
                if isOn { disabledIDs.remove(choice.id) } else { disabledIDs.insert(choice.id) }
            }
        )
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedRows: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(graphAuth.connectedName ?? "Connected")
                    .font(.body)
                if let email = graphAuth.connectedEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if graphAuth.needsReconnect {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Reconnect needed — your Microsoft sign-in expired.")
                    .font(.caption)
                Spacer()
                Button("Reconnect") { connectAndReload() }
                    .controlSize(.small)
            }
        }

        Toggle("Include Microsoft 365 events when matching", isOn: $graphEnabled)

        if graphEnabled && !graphCalendars.isEmpty {
            matchSubheader
            calendarToggleList(graphCalendars)
        }

        Button("Validate connection") {
            Task { await graphAuth.validate() }
        }
        .controlSize(.small)

        Button("Disconnect", role: .destructive) {
            graphAuth.disconnect()
            allCalendars = allCalendars.filter { $0.source != .microsoftGraph }
        }
        .controlSize(.small)

        if let error = graphAuth.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Disconnected

    @ViewBuilder
    private var disconnectedRows: some View {
        Text("Outlook / Teams calendar over Microsoft Graph. Paste the Entra Application (client) ID from a public-client app registration, then Connect.")
            .font(.caption)
            .foregroundStyle(.secondary)

        TextField("Application (client) ID", text: $graphClientID)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())

        Text("Redirect URI the app must list: \(GraphConfig.redirectURI)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)

        Button {
            connectAndReload()
        } label: {
            HStack {
                if graphAuth.isConnecting {
                    ProgressView().controlSize(.small)
                }
                Text(graphAuth.isConnecting ? "Connecting…" : "Connect Microsoft 365")
            }
        }
        .disabled(graphAuth.isConnecting || !isGraphClientReady)
        .helpTip(.settingsGraphConnect)

        Button("Validate connection") {
            Task { await graphAuth.validate() }
        }
        .disabled(!isGraphClientReady)
        .controlSize(.small)
        .helpTip(.settingsGraphConnect)

        if !isGraphClientReady {
            Text("Connect stays disabled until the client ID is a real GUID (not empty). Register a multi-tenant public client in Entra, allow public client flows, add Calendars.Read + User.Read + offline_access.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error = graphAuth.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
