//
//  SearchView.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Kingfisher
import SwiftUI

/// Lets menu commands ask the search field to take focus. SearchView consumes
/// the request on its next appearance, or immediately if already visible, and
/// clears it — so the one-shot survives the view being recreated when the user
/// switches sidebar sections.
@MainActor
@Observable
final class SearchFieldFocus {
    static let shared = SearchFieldFocus()
    var pending = false
    func requestFocus() {
        pending = true
    }
}

struct SearchView: View {
    @AppStorage("searchKey") var searchKey = ""
    @AppStorage("searchRegion") var searchRegion = "US"
    @FocusState var searchKeyFocused
    @State private var searchFocus = SearchFieldFocus.shared
    @State private var searchType = EntityType.iPhone

    @State private var searching = false
    @State private var searchPresented = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequestID = UUID()
    let regionKeys = ApplePackage.Configuration.storeFrontValues.keys.sorted {
        StoreRegionNames.name($0).localizedStandardCompare(StoreRegionNames.name($1)) == .orderedAscending
    }

    @State private var searchError: String?
    #if DEBUG
        @AppStorage("searchResults") // reduce API calls
        var searchResult: [AppStore.AppPackage] = []
    #else
        @State private var searchResult: [AppStore.AppPackage] = []
    #endif

    @State private var navigationPath = NavigationPath()
    @State private var vm = AppStore.this
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    var possibleRegion: Set<String> {
        vm.possibleRegions
    }

    var body: some View {
        navigationContent
            .onChange(of: searchFocus.pending) { _, pending in
                if pending { consumePendingFocus() }
            }
            .onChange(of: searchPresented) { _, presented in
                // The native close button ends the search presentation.
                // Pushing an app detail must keep the list for navigation back.
                if !presented && navigationPath.isEmpty { clearSearch() }
            }
    }

    private var navigationContent: some View {
        #if os(iOS)
            NavigationStack(path: $navigationPath) {
                if #available(iOS 26.0, *) {
                    modernContent
                } else {
                    legacyContent
                }
            }
        #else
            NavigationStack(path: $navigationPath) {
                legacyContent
            }
        #endif
    }

    var searchTypePicker: some View {
        Picker(selection: $searchType) {
            ForEach(EntityType.allCases) { type in
                Text(type.rawValue).tag(type)
            }
        } label: {
            Label("Type", systemImage: searchType.iconName)
        }
        .onChange(of: searchType) { _, _ in
            resetSearchResults()
        }
    }

    var possibleRegionKeys: [String] {
        regionKeys.filter { possibleRegion.contains($0) }
    }

    func searchRegionView() -> some View {
        Menu {
            if !possibleRegionKeys.isEmpty {
                buildPickView(
                    for: possibleRegionKeys,
                ) {
                    Label("Available Regions", systemImage: "checkmark.seal")
                }
                .pickerStyle(.inline)

                buildPickView(
                    for: regionKeys,
                ) {
                    Label("All Regions", systemImage: "globe")
                }
                .pickerStyle(.menu)
            } else {
                buildPickView(
                    for: regionKeys,
                ) {}
                    .pickerStyle(.inline)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(searchRegion.uppercased()).fixedSize()
            }
            .accessibilityLabel("商店地区：\(StoreRegionNames.name(searchRegion))")
        }
        .onChange(of: searchRegion) { _, _ in
            resetSearchResults()
        }
    }

    @ToolbarContentBuilder
    var tools: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                searchTypePicker
                    .labelsHidden()
                    .pickerStyle(.inline)
            } label: {
                Label("Type", systemImage: searchType.iconName)
            }
            .menuIndicator(.hidden)
        }

        ToolbarItem(placement: .automatic) {
            searchRegionView()
                .menuIndicator(.hidden)
        }
    }

    var content: some View {
        Form {
            if let searchError {
                Section {
                    Text(searchError)
                        .foregroundStyle(.red)
                }
            }
            if searching || !searchResult.isEmpty {
                Section(searching ? "Searching..." : "\(searchResult.count) Results") {
                    ForEach(searchResult) { item in
                        NavigationLink(value: ProductDestination(archive: item, region: searchRegion)) {
                            ArchivePreviewView(archive: item)
                        }
                    }
                    .transition(.opacity)
                }
                .transition(.opacity)
            }
        }
        .formStyle(.grouped)
        // Preserve result animations while searching. Search dismissal owns
        // its native title/keyboard animation and must not inherit our spring.
        .animation(searchPresented ? .spring : nil, value: searchError)
        .animation(searchPresented ? .spring : nil, value: searchResult)
        .animation(searchPresented ? .spring : nil, value: searching)
        .navigationDestination(for: ProductDestination.self) { dest in
            ProductView(archive: dest.archive, region: dest.region, navigationPath: $navigationPath)
        }
        .navigationDestination(for: PackageManifest.self) { manifest in
            PackageView(pkg: manifest)
        }
        .onAppear { consumePendingFocus() }
    }

    /// Focuses the search field if a focus request is pending (e.g. after the
    /// ⌘F menu command on macOS), then clears the request.
    private func consumePendingFocus() {
        guard searchFocus.pending else { return }
        searchFocus.pending = false
        // Defer so the search field exists when focus is assigned, whether the
        // view was already visible or is appearing for the first time.
        navigationPath = NavigationPath()
        searchKeyFocused = false
        searchPresented = true
        DispatchQueue.main.async { searchKeyFocused = true }
    }

    func buildPickView(for keys: [String], @ViewBuilder label: () -> some View) -> some View {
        Picker(selection: $searchRegion) {
            ForEach(keys, id: \.self) { key in
                Text("\(StoreRegionNames.name(key))  \(key)")
                    .tag(key)
            }
        } label: {
            label()
        }
    }

    private func resetSearchResults() {
        searchTask?.cancel()
        searchTask = nil
        searchRequestID = UUID()
        searching = false
        searchResult = []
        searchError = nil
    }

    private func clearSearch() {
        // Native search dismissal already owns focus and navigation-bar
        // geometry. Clear only our data, without starting a competing spring.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchKey = ""
            resetSearchResults()
        }
    }

    func search() {
        let term = searchKey
        let region = searchRegion
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchKeyFocused = false
            clearSearch()
            return
        }
        searchTask?.cancel()
        let requestID = UUID()
        searchRequestID = requestID
        searchKeyFocused = false
        searching = true
        searchError = nil
        let entityType = searchType
        logger.info("search: term=\(term) region=\(region) type=\(entityType.rawValue)")
        searchTask = Task { @MainActor in
            do {
                var result = try await ApplePackage.Searcher.search(
                    term: term,
                    countryCode: region,
                    limit: 32,
                    entityType: entityType,
                )
                try Task.checkCancellation()
                if let app = try? await ApplePackage.Lookup.lookup(
                    bundleID: term,
                    countryCode: region,
                    entityType: entityType,
                ) {
                    result.insert(app, at: 0)
                }
                try Task.checkCancellation()
                guard searchRequestID == requestID else { return }
                logger.info("search completed: \(result.count) results for term=\(term)")
                searching = false
                searchResult = result.map { AppStore.AppPackage(software: $0, entityType: entityType) }
                searchError = nil
                searchTask = nil
            } catch {
                guard !Task.isCancelled, searchRequestID == requestID else { return }
                logger.error("search failed: term=\(term) error=\(error.localizedDescription)")
                searching = false
                searchResult = []
                searchError = error.localizedDescription
                searchTask = nil
            }
        }
    }
}

struct ProductDestination: Hashable {
    let archive: AppStore.AppPackage
    let region: String
}

extension SearchView {
    var legacyContent: some View {
        content
            .searchable(text: $searchKey, isPresented: $searchPresented, prompt: "Keyword")
            .bindSearchFocus($searchKeyFocused)
            .onSubmit(of: .search) { search() }
            .navigationTitle("Search")
            .toolbar { tools }
    }
}

// MARK: - Liquid Glass

#if os(iOS)
    @available(iOS 26.0, *)
    extension SearchView {
        var modernContent: some View {
            content
                .searchable(text: $searchKey, isPresented: $searchPresented, placement: searchablePlacement, prompt: "Keyword")
                .searchFocused($searchKeyFocused)
                .onSubmit(of: .search) { search() }
                .navigationTitle("Search")
                .toolbar { tools }
        }

        var searchablePlacement: SearchFieldPlacement {
            .navigationBarDrawer(displayMode: .always)
        }
    }
#endif

#if DEBUG
    private typealias AppPackages = [AppStore.AppPackage]
    extension AppPackages: @retroactive RawRepresentable {
        public init?(rawValue: String) {
            guard
                let data = rawValue.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([AppStore.AppPackage].self, from: data)
            else { return nil }

            self = decoded
        }

        public var rawValue: String {
            guard let data = try? JSONEncoder().encode(self),
                  let rawValue = String(data: data, encoding: .utf8)
            else { return "" }

            return rawValue
        }
    }
#endif

extension ApplePackage.EntityType {
    var iconName: String {
        switch self {
        case .iPhone:
            "iphone"
        case .iPad:
            "ipad"
        case .appleTV:
            "appletv"
        }
    }
}




private extension View {
    @ViewBuilder
    func bindSearchFocus(_ focus: FocusState<Bool>.Binding) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            searchFocused(focus)
        } else {
            self // The app's UIKit search bridge handles iOS 17 focus.
        }
        #else
        searchFocused(focus)
        #endif
    }
}
