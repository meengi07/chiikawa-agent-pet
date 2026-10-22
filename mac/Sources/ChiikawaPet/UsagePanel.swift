import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let petInk = Color(red: 0.24, green: 0.22, blue: 0.29)
private let petPaper = Color(red: 1, green: 0.98, blue: 0.95)

struct UsagePanel: View {
    static let width: CGFloat = 380
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView(.vertical) { content }
            .frame(width: Self.width)
            .background(petPaper)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(petInk.opacity(0.08)))
            .environment(\.locale, store.language.locale)
            .environment(\.colorScheme, .light)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("Language / 언어", selection: $store.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(PetCharacter.allCases) { character in
                    CharacterCard(character: character, isSelected: store.selectedCharacter == character) { store.selectedCharacter = character }
                }
            }
            petSettings
            if store.previewPercent != nil {
                Text(T("표정 미리보기 · 실제 사용량이 아닙니다")).foregroundStyle(.orange)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 10) {
                    ForEach(store.visibleProviders) { display in
                        ProviderCard(display: display, refreshing: store.isRefreshing, isPreview: store.previewPercent != nil,
                                     countdown: store.settings.countdown, showPace: store.settings.showPace, now: context.date)
                    }
                }
            }
            if let culprit = store.moodCulprit {
                Text("\(T("표정 기준")): \(culprit.display.account.label) · \(T(culprit.window.title)) · \(Int(culprit.window.remainingPercent))%")
                    .font(.caption).foregroundStyle(.secondary)
                if store.settings.paceMood, let reading = culprit.display.currentReading,
                   let projection = UsagePace.projection(for: culprit.window, measuredAt: reading.fetchedAt, now: .now),
                   projection.severity > 0 {
                    Text(T("예측 페이스가 표정에 반영되어 있습니다.")).font(.caption2).foregroundStyle(.orange)
                }
            } else { Text(T("표정 기준: 현재 유효한 측정값이 없습니다.")).font(.caption).foregroundStyle(.secondary) }
            ExperienceSettings(store: store)
            HStack {
                Button(T("사용량 새로고침 / 연결")) { Task { await store.refresh(allowKeychainPrompt: true) } }
                    .disabled(store.isRefreshing || store.previewPercent != nil)
                Spacer()
                Button(T("종료")) { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            Text(T("클릭: 사용량 · 드래그: 이동 · 우클릭: 메뉴")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22).foregroundStyle(petInk).frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, store.language.locale).environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("CHIIKAWA PET").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Text(T("\(store.selectedCharacter.name)의 에너지")).font(.system(size: 23, weight: .bold, design: .rounded))
                Text(store.mood.caption).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            SpritePreview(character: store.selectedCharacter, remainingPercent: store.remainingPercent, mood: store.mood)
                .frame(width: 68, height: 84).accessibilityHidden(true).allowsHitTesting(false)
        }
    }

    private var petSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(T("펫 크기"))
                Text("\(Int((store.petScale * 100).rounded()))%").monospacedDigit()
                Spacer()
                Button(T("기본값 65%")) { store.setPetScale(UsageStore.defaultPetScale) }.controlSize(.small)
            }
            Slider(value: Binding(get: { store.petScale }, set: { store.setPetScale($0) }), in: UsageStore.petScaleRange, step: 0.05) {
                Text(T("펫 크기"))
            } minimumValueLabel: { Text("40%") } maximumValueLabel: { Text("120%") }
            Toggle(T("화면에 펫 표시"), isOn: $store.isPetVisible)
            Toggle(T("느긋하게 산책하기"), isOn: $store.wanders)
            Text(T("숨겨도 메뉴바에서 사용량과 펫을 확인할 수 있어요.")).font(.caption2).foregroundStyle(.secondary)
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
    }
}

private struct CharacterCard: View {
    let character: PetCharacter
    let isSelected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                SpritePreview(character: character, remainingPercent: 80, mood: .happy, animated: false)
                    .frame(width: 76, height: 84).accessibilityHidden(true).allowsHitTesting(false)
                Text(character.name).font(.system(size: 12, weight: isSelected ? .bold : .medium))
            }
            .padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(isSelected ? Color(red: 0.95, green: 0.85, blue: 0.79) : .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(petInk.opacity(isSelected ? 0.6 : 0.1), lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).padding(7) }
            }
        }.buttonStyle(.plain).accessibilityLabel(T("\(character.name) 선택"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProviderCard: View {
    let display: ProviderDisplay
    let refreshing: Bool
    let isPreview: Bool
    let countdown: Bool
    let showPace: Bool
    let now: Date
    private var accent: Color { display.provider == .claude ? Color(red: 0.78, green: 0.46, blue: 0.34) : Color(red: 0.32, green: 0.52, blue: 0.46) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(display.account.label).font(.system(size: 15, weight: .bold))
                Spacer()
                if let percent = display.reading?.remainingPercent {
                    Text("\(Int(percent.rounded(.down)))%").font(.system(size: 25, weight: .bold, design: .rounded))
                } else { Text(T(refreshing ? "조회 중…" : "조회 불가")).font(.caption).foregroundStyle(.secondary) }
            }
            if let reading = display.reading {
                metadata(reading)
                ForEach(reading.windows, id: \.id) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(T(window.title)); Spacer(); Text("\(Int(window.remainingPercent.rounded(.down)))%").monospacedDigit() }.font(.caption)
                        ProgressView(value: window.remainingPercent, total: 100).tint(accent)
                        if let reset = window.resetsAt { Text(resetText(reset)).font(.caption2).foregroundStyle(.secondary) }
                        if showPace, display.error == nil, reading.isCurrent(at: now),
                           let projection = UsagePace.projection(for: window, measuredAt: reading.fetchedAt, now: now) {
                            Text(projection.severity == 2 ? T("이 속도면 초기화 전에 한도에 도달합니다.") :
                                 projection.severity == 1 ? T("초기화 전 남을 여유가 적습니다.") : T("현재 속도라면 초기화까지 여유가 있습니다."))
                                .font(.caption2).foregroundStyle(projection.severity == 2 ? .orange : .secondary)
                            Text("\(T("초기화 시 예상 잔여량")) \(Int(projection.remainingAtReset))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(reading.extras) { extra in
                    HStack {
                        Text(T(extra.title))
                        Spacer()
                        Text("\(extra.amount.formatted(.number.precision(.fractionLength(0...2)))) \(extra.unit)" + (extra.limit.map { " / \($0.formatted()) \(extra.unit)" } ?? ""))
                    }.font(.caption)
                }
                Text("\(T("측정 시각")): \(reading.fetchedAt.formatted(date: .abbreviated, time: .standard)) · \(max(0, Int(now.timeIntervalSince(reading.fetchedAt) / 60)))\(T("분 전"))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let attempted = display.attemptedAt {
                Text("\(T("마지막 조회 시도")): \(attempted.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary)
            }
            if let retry = display.retryAt, retry > now {
                Text("\(T("다음 시도")): \(retry.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.orange)
            }
            if let error = display.error { Text(T(error)).font(.caption).foregroundStyle(.red) }
        }.padding(14).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.14)))
    }

    private func metadata(_ reading: UsageReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if isPreview {
                Text(T("표정 미리보기 · 실제 사용량이 아닙니다")).foregroundStyle(.orange)
            } else {
                Text(T(reading.source == .diskCache ? "저장된 마지막 정상값" : display.error != nil || !reading.isCurrent(at: now) ? "이전 데이터" : reading.source == .swapCache ? "CLI 캐시 · 현재 측정값" : "API · 현재 측정값"))
                    .foregroundStyle(reading.source == .diskCache || display.error != nil || !reading.isCurrent(at: now) ? Color.orange : Color.secondary)
            }
            Text("\(T("확인된 계정")): \(reading.accountLabel ?? T("알 수 없음"))")
            Text("\(T("플랜")): \(reading.plan ?? T("알 수 없음")) · \(T("인증 출처")): \(reading.authSource ?? T("알 수 없음"))")
        }.font(.caption2)
    }

    private func resetText(_ reset: Date) -> String {
        if countdown {
            let seconds = max(0, Int(reset.timeIntervalSince(now)))
            if seconds == 0 { return T("초기화 시각 경과 · 새 측정 대기") }
            return "\(seconds / 3600)\(T("시간")) \((seconds % 3600) / 60)\(T("분 후 초기화"))"
        }
        return T("\(reset.formatted(.dateTime.year().month().day().hour().minute().locale(AppLanguage.current.locale))) 초기화")
    }
}

private struct ExperienceSettings: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(T("표정과 예측")) { moodSettings }
            DisclosureGroup(T("메뉴바 표시")) { menuSettings }
            DisclosureGroup(T("계정과 연결")) { accountSettings }
            DisclosureGroup(T("알림과 시스템")) { systemSettings }
            DisclosureGroup(T("로컬 사용 기록과 비용")) { HistorySettings(store: store) }
            Button(T("토큰 없는 진단 복사")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.diagnosticText, forType: .string)
            }
            Button(T("새 기능 설정만 기본값으로")) { store.resetExperience() }
                .foregroundStyle(.secondary).disabled(store.previewPercent != nil)
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
    }

    private var metrics: [String] {
        var ids = Set(["session", "weekly"])
        for display in store.providers { for window in display.reading?.windows ?? [] { ids.insert(window.id) } }
        return ids.sorted()
    }
    private var moodSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(T("반응 대상"), selection: $store.settings.moodAccountID) {
                Text(T("전체 최솟값")).tag("all")
                Text("Claude").tag("Claude")
                Text("Codex").tag("Codex")
                ForEach(store.providers) { Text($0.account.label).tag($0.id) }
            }
            Picker(T("한도"), selection: $store.settings.moodMetricID) {
                Text(T("모든 한도")).tag("all")
                ForEach(metrics, id: \.self) { Text(metricTitle($0)).tag($0) }
            }
            ForEach(0..<4, id: \.self) { index in
                HStack {
                    Text(T(["울음 경계", "슬픔 경계", "걱정 경계", "밝음 경계"][index]))
                    Slider(value: Binding(get: { store.settings.thresholds[index] }, set: { proposed in
                        let lower = index == 0 ? 0 : store.settings.thresholds[index - 1]
                        let upper = index == 3 ? 100 : store.settings.thresholds[index + 1]
                        store.settings.thresholds[index] = min(max(proposed, lower), upper)
                    }), in: 0...100, step: 1)
                    Text("\(Int(store.settings.thresholds[index]))%").frame(width: 34)
                }
            }
            Toggle(T("예측 페이스도 표정에 반영"), isOn: $store.settings.paceMood)
            Toggle(T("초기화까지 카운트다운"), isOn: $store.settings.countdown)
            Toggle(T("조건부 사용 페이스 표시"), isOn: $store.settings.showPace)
            Text(T("예측은 최신 측정과 알려진 한도 기간이 있을 때만 표시합니다.")).font(.caption2).foregroundStyle(.secondary)
        }.padding(.top, 8)
    }

    private var menuSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(T("백분율 대신 막대"), isOn: $store.settings.menuBars)
            Toggle(T("간결한 표시"), isOn: $store.settings.menuCompact)
            Text(T("핀 없음: 기본 표시. 아래에서 한도를 선택하고 순서를 바꾸세요.")).font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(store.settings.menuPins.enumerated()), id: \.element.id) { index, pin in
                HStack {
                    Text(pinLabel(pin)).lineLimit(2)
                    Spacer()
                    Button { store.settings.menuPins.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).accessibilityLabel(T("핀 위로 이동"))
                    Button { store.settings.menuPins.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index + 1 == store.settings.menuPins.count).accessibilityLabel(T("핀 아래로 이동"))
                    Button { store.settings.menuPins.removeAll { $0.id == pin.id } } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel(T("핀 제거"))
                }
            }
            ForEach(store.providers) { display in
                ForEach(pinMetrics(display), id: \.self) { metricID in
                    let pin = MenuPin(accountID: display.id, metricID: metricID)
                    Toggle("\(display.account.label) · \(metricTitle(metricID))", isOn: Binding(get: { store.settings.menuPins.contains(pin) }, set: { enabled in
                        if enabled { store.settings.menuPins.append(pin) } else { store.settings.menuPins.removeAll { $0.id == pin.id } }
                    }))
                }
            }
            Button(T("기본 메뉴바 구성")) { store.settings.menuPins = []; store.settings.menuBars = false; store.settings.menuCompact = false }
        }.padding(.top, 8)
    }

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(T("저장된 cswap / xswap 계정 검색"), isOn: Binding(get: { store.settings.discoverSavedAccounts }, set: { enabled in
                store.settings.discoverSavedAccounts = enabled
                store.reloadAccounts()
                Task { await store.refresh(); await store.loadHistory() }
            }))
            Text(T("읽기 전용 연결입니다. 로그인 전환·토큰 갱신·인증 파일 수정은 하지 않습니다.")).font(.caption2).foregroundStyle(.secondary)
            if let warning = store.discoveryWarning { Text(T(warning)).font(.caption2).foregroundStyle(.orange) }
            ForEach(store.providers) { display in
                HStack {
                    Toggle(display.account.label, isOn: Binding(get: { !store.settings.hiddenAccountIDs.contains(display.id) }, set: { visible in
                        if visible { store.settings.hiddenAccountIDs.removeAll { $0 == display.id } }
                        else { store.settings.hiddenAccountIDs.append(display.id) }
                    }))
                    if store.settings.additionalAccounts.contains(where: { $0.id == display.id }) {
                        Button(T("연결 제거")) { store.removeHome(id: display.id) }
                    }
                }
            }
            Text(T("카드 숨김은 표정 대상에서 제외하지 않습니다.")).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(T("Claude 홈 추가…")) { pickHome(.claude) }
                Button(T("Codex 홈 추가…")) { pickHome(.codex) }
            }
        }.padding(.top, 8)
    }

    private var systemSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(T("잔여량 알림"), isOn: Binding(get: { store.settings.notifications }, set: { store.setNotifications($0) }))
            Toggle(T("페이스 악화 알림도 받기"), isOn: $store.settings.paceNotifications).disabled(!store.settings.notifications)
            Text(T("울음·슬픔 경계 진입 시 알림. 실행 직후와 이전 데이터는 알리지 않습니다.")).font(.caption2).foregroundStyle(.secondary)
            Toggle(T("로그인 시 시작"), isOn: Binding(get: { store.settings.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            HStack {
                Text(T("패널 전역 단축키"))
                ShortcutRecorder(shortcut: store.settings.shortcut, onRecord: store.setShortcut).frame(height: 26)
                Button(T("지우기")) { store.setShortcut(nil) }
            }
            Text(T("접근성 권한 없이 등록합니다. 다른 앱과 충돌하면 새 조합을 기록하세요.")).font(.caption2).foregroundStyle(.secondary)
            if let error = store.systemError { Text(T(error)).font(.caption).foregroundStyle(.red) }
        }.padding(.top, 8).disabled(store.previewPercent != nil)
    }

    private func pinMetrics(_ display: ProviderDisplay) -> [String] {
        var ids = Set(["session", "weekly"])
        for window in display.reading?.windows ?? [] { ids.insert(window.id) }
        return ids.sorted()
    }

    private func pinLabel(_ pin: MenuPin) -> String {
        let account = store.providers.first { $0.id == pin.accountID }
        let window = account?.reading?.windows.first { $0.id == pin.metricID }
        return "\(account?.account.label ?? T("연결 필요")) · \(window.map { T($0.title) } ?? metricTitle(pin.metricID))"
    }
    private func metricTitle(_ id: String) -> String {
        if id == "session" { return T("세션") }
        if id == "weekly" { return T("주간") }
        for display in store.providers {
            if let window = display.reading?.windows.first(where: { $0.id == id }) { return T(window.title) }
        }
        return id
    }
    private func pickHome(_ provider: UsageProvider) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = T("CLI 설정 홈을 선택하세요. 인증 파일은 수정하지 않습니다.")
        if panel.runModal() == .OK, let url = panel.url { store.addHome(provider: provider, directory: url) }
    }
}

private struct HistorySettings: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(T("로컬 일별 기록 읽기"), isOn: Binding(get: { store.settings.historyEnabled }, set: { enabled in
                store.settings.historyEnabled = enabled
                Task { await store.loadHistory() }
            }))
            Text(T("홈별 로컬 로그 집계이며 현재 계정 소유 기록으로 간주하지 않습니다. 같은 홈은 한 번만 셉니다. 대화 내용은 표시하지 않습니다."))
                .font(.caption2).foregroundStyle(.secondary)
            Picker(T("기간"), selection: $store.settings.historyPeriod) {
                ForEach(HistoryPeriod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Button(T("가격 JSON 선택…")) { pickPricing() }
                if store.settings.pricingFile != nil { Button(T("가격 파일 해제")) { store.settings.pricingFile = nil; Task { await store.loadHistory() } } }
            }.disabled(!store.settings.historyEnabled)
            Text(T("추정 API 환산액은 구독 청구액이 아닙니다. 미등록 모델은 가격 미상으로 남습니다."))
                .font(.caption2).foregroundStyle(.secondary)
            Text(T("비용 추정에는 직접 선택한 가격 JSON이 필요합니다. 선택하지 않아도 토큰 기록은 볼 수 있습니다."))
                .font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup(T("가격 파일 형식")) {
                Text("{\"version\":1,\"models\":{\"exact-model-id\":{\"inputPerMillion\":3,\"outputPerMillion\":15,\"cachedInputPerMillion\":0.3,\"cacheWritePerMillion\":3.75}}}")
                    .font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                Text(T("단위: USD / 백만 토큰. 모든 요율은 유한한 0 이상 숫자여야 합니다. 1시간 캐시 쓰기는 선택 항목 cacheWriteOneHourPerMillion이 필요합니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if store.isLoadingHistory { ProgressView().controlSize(.small) }
            ForEach(store.histories) { history in
                Text("\(history.label) · \(T("홈별 집계"))").bold()
                if let summary = history.summary {
                    let days = store.settings.historyPeriod.days(from: summary.days)
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(day.day)
                                Spacer()
                                Text("\(day.totalTokens.formatted()) \(T("토큰"))")
                            }
                            Text("\(T("입력")) \(day.inputTokens) · \(T("출력")) \(day.outputTokens) · \(T("캐시")) \(day.cachedTokens)")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let estimate = day.estimatedCost { Text("≈ USD \(estimate.formatted(.number.precision(.fractionLength(2...4))))").font(.caption2) }
                            if day.unpricedTokens > 0 { Text("\(T("가격 미상 토큰")): \(day.unpricedTokens.formatted())").font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                    if days.isEmpty { Text(T("읽을 사용 기록이 없습니다.")).foregroundStyle(.secondary) }
                    if let warning = summary.warning { Text(T(warning)).font(.caption2).foregroundStyle(.orange) }
                }
                if let error = history.error { Text(T(error)).font(.caption2).foregroundStyle(.red) }
            }
            Button(T("기록 새로고침")) { Task { await store.loadHistory() } }
                .disabled(!store.settings.historyEnabled || store.isLoadingHistory)
        }.padding(.top, 8)
    }
    private func pickPricing() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = T("선택한 로컬 JSON 요율만 사용합니다. 네트워크로 보내지 않습니다.")
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.pricingFile = url.path
            Task { await store.loadHistory() }
        }
    }
}

private struct SpritePreview: NSViewRepresentable {
    let character: PetCharacter
    let remainingPercent: Double?
    let mood: PetMood
    var animated = true
    func makeNSView(context: Context) -> PixelPetView { PixelPetView(frame: .zero) }
    func updateNSView(_ view: PixelPetView, context: Context) {
        view.character = character
        view.remainingPercent = remainingPercent
        view.moodOverride = mood
        view.animationEnabled = animated && !context.environment.accessibilityReduceMotion
    }
}
