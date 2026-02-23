import SwiftUI
import UIKit

private enum RootTab: Hashable {
    case data
    case chat
    case more
}

private enum ChatRole {
    case user
    case assistant
    case system
}

private struct ChatLine: Identifiable {
    let id: UUID
    let role: ChatRole
    var text: String

    init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ReceiptCaptureViewModel()
    @State private var selectedTab: RootTab = .data

    var body: some View {
        TabView(selection: $selectedTab) {
            ReceiptDashboardTab(viewModel: viewModel)
                .tabItem {
                    Label("Data", systemImage: "chart.bar.doc.horizontal")
                }
                .tag(RootTab.data)

            ChatTab(viewModel: viewModel)
                .tabItem {
                    Label("Chat", systemImage: "message")
                }
                .tag(RootTab.chat)

            PlaceholderTab()
                .tabItem {
                    Label("More", systemImage: "square.grid.2x2")
                }
                .tag(RootTab.more)
        }
        .alert("Couldn’t process request", isPresented: $viewModel.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}

private struct ReceiptDashboardTab: View {
    @ObservedObject var viewModel: ReceiptCaptureViewModel
    @State private var showingCameraPicker = false
    @State private var showingCameraUnavailableAlert = false

    var body: some View {
        NavigationStack {
            List {
                if let infoMessage = viewModel.infoMessage {
                    Section {
                        Text(infoMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Storage") {
                    Text("Receipts are stored in Mnexium Records only. Nothing is saved on-device.")
                        .foregroundStyle(.secondary)
                }

                Section("Receipts") {
                    if viewModel.isLoadingReceipts && viewModel.receipts.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading receipts...")
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.receipts.isEmpty {
                        Text(viewModel.receiptsLoadMessage ?? "No receipts synced yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.receipts) { receipt in
                            NavigationLink {
                                ReceiptItemsSheet(receipt: receipt, viewModel: viewModel)
                            } label: {
                                ReceiptRow(receipt: receipt)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cartly")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await viewModel.refreshReceipts(force: true)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showingCameraPicker = true
                        } else {
                            showingCameraUnavailableAlert = true
                        }
                    } label: {
                        Image(systemName: "camera")
                    }
                }
            }
            .overlay {
                if viewModel.isProcessing {
                    ProgressView("Analyzing receipt...")
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .sheet(isPresented: $showingCameraPicker) {
                ImagePicker(sourceType: .camera) { image in
                    Task {
                        await viewModel.captureReceipt(from: image)
                    }
                }
            }
            .alert("Camera Unavailable", isPresented: $showingCameraUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This device does not have an available camera.")
            }
            .task {
                await viewModel.refreshReceipts(force: false)
            }
        }
    }
}

private struct ChatTab: View {
    @ObservedObject var viewModel: ReceiptCaptureViewModel

    @State private var draft = ""
    @State private var isSending = false
    @State private var showingChatDrawer = false
    @State private var isLoadingChats = false
    @State private var chatSummaries: [MnexiumChatSummary] = []
    @State private var chatListMessage: String?
    @State private var activeChatID = ""
    @State private var isLoadingActiveHistory = false
    @FocusState private var isComposerFocused: Bool
    @State private var lines: [ChatLine] = [
        ChatLine(role: .assistant, text: "Hi, I can help with spend questions and receipt insights.")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    Text("Chat")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()
                    Button {
                        activeChatID = viewModel.activeChatID()
                        showingChatDrawer = true
                        Task {
                            await loadChats(forceRefresh: true)
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.title3)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)

                if !activeChatID.isEmpty {
                    HStack(spacing: 8) {
                        Text("Active chat:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(activeChatID)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isLoadingActiveHistory {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(lines) { line in
                                ChatBubble(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        isComposerFocused = false
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last {
                            withAnimation {
                                reader.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Ask about spending...", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($isComposerFocused)

                    Button {
                        isComposerFocused = false
                        sendMessage()
                    } label: {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || isLoadingActiveHistory)
                }
                .padding()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isComposerFocused = false
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingChatDrawer) {
                NavigationStack {
                    Group {
                        if isLoadingChats {
                            ProgressView("Loading chats...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let chatListMessage {
                            ContentUnavailableView(
                                "Couldn’t load chats",
                                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                description: Text(chatListMessage)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                Section {
                                    Button {
                                        startNewChat(closeDrawer: true)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "plus.bubble.fill")
                                                .foregroundStyle(.blue)
                                            Text("New Chat")
                                                .fontWeight(.semibold)
                                            Spacer()
                                        }
                                    }
                                    .disabled(isLoadingActiveHistory)
                                }

                                Section("Previous Chats") {
                                    if chatSummaries.isEmpty {
                                        Text("No previous chats yet.")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(chatSummaries) { chat in
                                            Button {
                                                Task {
                                                    await selectChat(chat.chatID)
                                                }
                                            } label: {
                                                HStack(alignment: .center, spacing: 10) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(chat.title)
                                                            .font(.headline)
                                                            .lineLimit(1)

                                                        HStack(spacing: 8) {
                                                            Text(chat.chatID)
                                                                .font(.caption)
                                                                .foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                                .truncationMode(.middle)

                                                            if let count = chat.messageCount {
                                                                Text("\(count) messages")
                                                                    .font(.caption)
                                                                    .foregroundStyle(.secondary)
                                                            }

                                                            Spacer()

                                                            if let updatedAt = chat.updatedAt ?? chat.createdAt {
                                                                Text(updatedAt, format: .dateTime.month().day().hour().minute())
                                                                    .font(.caption)
                                                                    .foregroundStyle(.secondary)
                                                            }
                                                        }
                                                    }

                                                    if chat.chatID == activeChatID {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundStyle(.green)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 2)
                                            .buttonStyle(.plain)
                                            .disabled(isLoadingActiveHistory)
                                        }
                                    }
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                    .navigationTitle("Chats")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Refresh") {
                                Task {
                                    await loadChats(forceRefresh: true)
                                }
                            }
                            .disabled(isLoadingChats)
                        }
                    }
                    .task {
                        await loadChats(forceRefresh: false)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .onAppear {
                startNewChat(closeDrawer: false)
            }
        }
    }

    private func sendMessage() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }

        lines.append(ChatLine(role: .user, text: message))
        draft = ""
        isSending = true

        let assistantID = UUID()
        lines.append(ChatLine(id: assistantID, role: .assistant, text: ""))

        Task {
            var streamedText = ""
            do {
                let stream = viewModel.streamChatMessage(message)
                for try await chunk in stream {
                    streamedText += chunk
                    if let index = lines.firstIndex(where: { $0.id == assistantID }) {
                        lines[index].text = streamedText
                    }
                }
                if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let index = lines.firstIndex(where: { $0.id == assistantID }) {
                    lines[index].text = "No response received."
                }
                } catch {
                    viewModel.logError(error, context: "chat_send")
                    let failureMessage = viewModel.chatFailureMessage(for: error)
                    if let index = lines.firstIndex(where: { $0.id == assistantID }) {
                        if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lines.remove(at: index)
                            lines.append(ChatLine(role: .system, text: failureMessage))
                        } else {
                            lines[index].text = streamedText
                        }
                    } else {
                        lines.append(ChatLine(role: .system, text: failureMessage))
                    }
                }

            isSending = false
        }
    }

    private func loadChats(forceRefresh: Bool) async {
        if isLoadingChats {
            return
        }
        if !forceRefresh, !chatSummaries.isEmpty {
            return
        }

        isLoadingChats = true
        chatListMessage = nil

        do {
            activeChatID = viewModel.activeChatID()
            chatSummaries = try await viewModel.listChats()
        } catch {
            viewModel.logError(error, context: "list_chats")
            chatSummaries = []
            chatListMessage = "Please try again in a moment."
        }

        isLoadingChats = false
    }

    private func selectChat(_ chatID: String) async {
        viewModel.activateChat(chatID: chatID)
        activeChatID = chatID
        showingChatDrawer = false
        draft = ""
        isLoadingActiveHistory = true
        lines = [ChatLine(role: .system, text: "Loading chat history...")]

        do {
            let history = try await viewModel.readChatHistory(chatID: chatID)
            if activeChatID == chatID {
                let mapped = history.map(mapHistoryMessageToLine)
                if mapped.isEmpty {
                    lines = [ChatLine(role: .assistant, text: "This chat is empty. Send a message to start.")]
                } else {
                    lines = mapped
                }
            }
        } catch {
            viewModel.logError(error, context: "read_chat_history")
            if activeChatID == chatID {
                lines = [ChatLine(role: .system, text: "Couldn’t load this chat yet. You can still send a new message.")]
            }
        }

        if activeChatID == chatID {
            isLoadingActiveHistory = false
        }
    }

    private func startNewChat(closeDrawer: Bool) {
        activeChatID = viewModel.startNewChatSession()
        if closeDrawer {
            showingChatDrawer = false
        }
        draft = ""
        isSending = false
        isLoadingActiveHistory = false
        lines = [
            ChatLine(role: .assistant, text: "Hi, I can help with spend questions and receipt insights.")
        ]
    }

    private func mapHistoryMessageToLine(_ message: MnexiumHistoryMessage) -> ChatLine {
        let normalizedRole = message.role.lowercased()
        let role: ChatRole
        if normalizedRole.contains("user") {
            role = .user
        } else if normalizedRole.contains("assistant") || normalizedRole.contains("ai") || normalizedRole.contains("model") {
            role = .assistant
        } else {
            role = .system
        }
        return ChatLine(role: role, text: message.content)
    }
}

private struct ChatBubble: View {
    let line: ChatLine

    var body: some View {
        HStack {
            if line.role == .user {
                Spacer(minLength: 40)
            }

            Text(line.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if line.role != .user {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var background: Color {
        switch line.role {
        case .user:
            return .blue
        case .assistant:
            return Color(.secondarySystemBackground)
        case .system:
            return .orange.opacity(0.2)
        }
    }

    private var foreground: Color {
        line.role == .user ? .white : .primary
    }
}

private struct PlaceholderTab: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("More coming soon")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Use this tab later for budgets, goals, or automation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .navigationTitle("More")
        }
    }
}

private struct ReceiptRow: View {
    let receipt: ReceiptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(receipt.storeName)
                    .font(.headline)

                Spacer()

                Text(receipt.total, format: .currency(code: normalizedCurrency))
                    .font(.headline)
            }

            HStack(spacing: 8) {
                Label {
                    Text(receipt.purchasedAt, format: .dateTime.year().month().day())
                } icon: {
                    Image(systemName: "calendar")
                }
                .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }
        }
        .padding(.vertical, 4)
    }

    private var normalizedCurrency: String {
        receipt.currency.isEmpty ? "USD" : receipt.currency
    }
}

private struct ReceiptItemRow: View {
    let item: ReceiptItemEntry
    let currency: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.itemName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let category = item.category, !category.isEmpty {
                    Text(category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let quantity = item.quantity {
                    Text("Qty \(quantity.formatted(.number.precision(.fractionLength(0...2))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let lineTotal = item.lineTotal {
                Text(lineTotal, format: .currency(code: normalizedCurrency))
                    .font(.caption)
                    .fontWeight(.semibold)
            } else if let unitPrice = item.unitPrice {
                Text(unitPrice, format: .currency(code: normalizedCurrency))
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
    }

    private var normalizedCurrency: String {
        currency.isEmpty ? "USD" : currency
    }
}

private struct ReceiptItemsSheet: View {
    let receipt: ReceiptEntry
    @ObservedObject var viewModel: ReceiptCaptureViewModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.storeName)
                        .font(.headline)
                    Text(receipt.purchasedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Items") {
                if viewModel.loadingReceiptItemIDs.contains(receipt.id) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading items...")
                            .foregroundStyle(.secondary)
                    }
                } else if let message = viewModel.receiptItemsLoadMessages[receipt.id] {
                    Text(message)
                        .foregroundStyle(.secondary)
                } else if let items = viewModel.receiptItemsByReceiptID[receipt.id], !items.isEmpty {
                    ForEach(items) { item in
                        ReceiptItemRow(item: item, currency: receipt.currency)
                    }
                } else {
                    Text("No items found for this receipt.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Receipt Items")
        .refreshable {
            await viewModel.loadReceiptItems(receiptID: receipt.id, force: true)
        }
        .task(id: receipt.id) {
            await viewModel.loadReceiptItems(receiptID: receipt.id, force: false)
        }
    }
}
