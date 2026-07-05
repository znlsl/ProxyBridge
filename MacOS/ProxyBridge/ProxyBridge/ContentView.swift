import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: ProxyBridgeViewModel
    @State private var selectedTab = 0
    @State private var connectionSearchText = ""
    @State private var activitySearchText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            tabSelector
            Divider()
            contentView
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    private var headerView: some View {
        HStack {
            Text("ProxyBridge")
                .font(.headline)
                .padding(.leading)
            Spacer()
        }
        .frame(height: 44)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var tabSelector: some View {
        HStack(spacing: 0) {
            TabButton(title: "Connections", isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            TabButton(title: "Activity Logs", isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            Spacer()
        }
        .frame(height: 40)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var contentView: some View {
        Group {
            if selectedTab == 0 {
                ConnectionsView(
                    connections: filteredConnections,
                    searchText: $connectionSearchText,
                    onClear: viewModel.clearConnections
                )
            } else {
                ActivityLogsView(
                    logs: filteredActivityLogs,
                    searchText: $activitySearchText,
                    onClear: viewModel.clearActivityLogs
                )
            }
        }
    }
    
    private var filteredConnections: [ProxyBridgeViewModel.ConnectionLog] {
        let q = connectionSearchText
        if q.isEmpty {
            return viewModel.connections
        }
        // match against every field so a search finds protocol, ip, port, process, proxy or time
        return viewModel.connections.filter {
            $0.timestamp.localizedCaseInsensitiveContains(q) ||
            $0.connectionProtocol.localizedCaseInsensitiveContains(q) ||
            $0.process.localizedCaseInsensitiveContains(q) ||
            $0.destination.localizedCaseInsensitiveContains(q) ||
            $0.port.localizedCaseInsensitiveContains(q) ||
            $0.proxy.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredActivityLogs: [ProxyBridgeViewModel.ActivityLog] {
        let q = activitySearchText
        if q.isEmpty {
            return viewModel.activityLogs
        }
        return viewModel.activityLogs.filter {
            $0.timestamp.localizedCaseInsensitiveContains(q) ||
            $0.level.localizedCaseInsensitiveContains(q) ||
            $0.message.localizedCaseInsensitiveContains(q)
        }
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct ConnectionsView: View {
    let connections: [ProxyBridgeViewModel.ConnectionLog]
    @Binding var searchText: String
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            LogTextView(text: connectionsText)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search connections...", text: $searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button("Clear", action: onClear)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var connectionsText: NSAttributedString {
        let out = NSMutableAttributedString()
        for c in connections {
            out.append(LogText.seg("[\(c.timestamp)] ", .secondaryLabelColor))
            out.append(LogText.seg("[\(c.connectionProtocol)] ", .systemBlue))
            out.append(LogText.seg(c.process, .systemGreen))
            out.append(LogText.seg(" → ", .secondaryLabelColor))
            out.append(LogText.seg("\(c.destination):\(c.port)", .systemOrange))
            out.append(LogText.seg(" → ", .secondaryLabelColor))
            out.append(LogText.seg(c.proxy, c.proxy == "Direct" ? .secondaryLabelColor : .systemPurple))
            out.append(LogText.seg("\n", .labelColor))
        }
        return out
    }
}

struct ActivityLogsView: View {
    let logs: [ProxyBridgeViewModel.ActivityLog]
    @Binding var searchText: String
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            LogTextView(text: logsText)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search logs...", text: $searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button("Clear", action: onClear)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var logsText: NSAttributedString {
        let out = NSMutableAttributedString()
        for log in logs {
            out.append(LogText.seg("[\(log.timestamp)] ", .secondaryLabelColor))
            out.append(LogText.seg("[\(log.level)] ", log.level == "ERROR" ? .systemRed : .systemBlue))
            out.append(LogText.seg(log.message, .labelColor))
            out.append(LogText.seg("\n", .labelColor))
        }
        return out
    }
}

// builds the colored, monospaced segments shared by both log views
enum LogText {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    static func seg(_ string: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.foregroundColor: color, .font: font])
    }
}

// read-only NSTextView so the whole log behaves like a text area, multi-row
// drag select, select all and copy all work like any text box
struct LogTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.font = LogText.font
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        // nothing changed, leave the current selection and scroll position alone
        if storage.string == text.string { return }

        // keep the user's selection if it still fits (holds while not trimming),
        // otherwise stick to the bottom so new lines stay in view
        let previousSelection = textView.selectedRanges
        let wasAtBottom = isScrolledToBottom(scrollView)

        storage.setAttributedString(text)

        let length = (text.string as NSString).length
        let validSelection = previousSelection.filter { value in
            let r = value.rangeValue
            return r.location + r.length <= length
        }

        if let sel = validSelection.first, sel.rangeValue.length > 0 {
            textView.selectedRanges = validSelection
        } else if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let visible = scrollView.contentView.bounds
        return visible.maxY >= docHeight - 24
    }
}
