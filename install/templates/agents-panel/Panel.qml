import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      // Duas coisas que a ordenacao precisa saber e o rotulo sozinho nao diz.
      // `long` separa o orcamento da semana da janela que rola o dia inteiro.
      // `scoped` marca limite de um modelo so ("Fable Weekly"): ele nao segura
      // a conta inteira, entao nao pode mandar na conta inteira.
      long: windowIsLong(String(label || "").toLowerCase()),
      scoped: String(title || "") !== ""
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  // ── as duas janelas nao respondem a mesma pergunta ────────────────────────
  //
  // A janela de 5 horas e um FREIO: ela volta sozinha varias vezes por dia, e
  // nada se perde quando ela vira. A semanal e o ORCAMENTO: vira uma vez, na
  // data, e o que nao foi usado ate la nao volta nunca.
  //
  // Misturar as duas foi o erro: a conta Team aparecia em primeiro porque a
  // janela de 5 horas dela virava em uma hora, enquanto a semanal so vira dia
  // 15. O conselho "use antes que vire" apontava para uma conta que nao tinha
  // nada para perder, e escondia a Papi Max, cuja semana fecha dia 12.
  //
  // Entao: o orcamento manda na ORDEM (o que se perde e quando), e o freio
  // manda em QUEM PODE ENTRAR na disputa (o que da para usar agora).

  function budgetWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (!w.long) continue
      // Limite da conta inteira ganha de limite de um modelo so, mesmo estando
      // menos cheio: e ele que decide se a conta serve para qualquer trabalho.
      if (!best) { best = w; continue }
      if (best.scoped !== w.scoped) { if (!w.scoped) best = w; continue }
      if (w.percent > best.percent) best = w
    }
    // Fornecedor de janela unica (o Codex so tem semanal) cai aqui de volta.
    return best || bindingWindow(p)
  }

  function throttleWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (w.long) continue
      if (!best || w.percent > best.percent) best = w
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  // ------------------------------------------------------------- overview
  //
  // A pergunta ao comecar algo novo nao e "onde sobra mais", e sim "o que vou
  // perder se nao usar". Cota que zera sem ser usada e cota jogada fora, entao
  // entre duas contas com folga a certa e a que RENOVA ANTES: os 49% de uma
  // janela que vira em sete horas somem hoje, enquanto os 100% de outra que so
  // vira daqui a uma semana continuam la amanha.
  //
  // Uma versao anterior ordenava por espaco livre e colocava no topo justamente
  // a conta sem pressa nenhuma, que e o conselho oposto do util.
  //
  // Conta apertada nao entra na disputa: sem folga de verdade nao ha o que
  // aproveitar antes do reset, e ela cai para o fim da lista.
  readonly property real usableFloor: 0.10

  function freeSpace(p) {
    var w = budgetWindow(p)
    if (!w) return -1
    return 1 - Number(w.percent)
  }

  // Quanto cabe AGORA, que e outra conta: a semana pode estar quase intacta e
  // a janela de 5 horas cheia, e ai a conta nao serve para comecar nada neste
  // momento. Sem freio declarado, nada esta segurando.
  function throttleFree(p) {
    var w = throttleWindow(p)
    if (!w) return 1
    return 1 - Number(w.percent)
  }

  // O fornecedor sai do id do registro, que e como o coletor os nomeia. O nome
  // da conta sozinho ("Exato", "Team") nao diz de quem e a assinatura, e com
  // contas de quatro fornecedores lado a lado isso e metade da informacao.
  function vendorOf(p) {
    // `providerId` e como Main.qml nomeia o campo; `id` nunca existiu aqui, e
    // por isso o fornecedor sumia de todos os rotulos em silencio: "Exato · pro"
    // em vez de "Exato · Codex pro".
    var id = String(p && (p.providerId || p.id) ? (p.providerId || p.id) : "")
    if (id === "claude" || id.indexOf("claude-") === 0) return "Claude"
    if (id.indexOf("codex") === 0) return "Codex"
    if (id.indexOf("ezomar-ai-usagebar-") === 0) return ""   // o nome ja e a marca
    return ""
  }

  // "Exato · Codex pro". O fornecedor cai fora quando ja esta no nome da conta,
  // para nao virar "Kimi · Kimi Vivace".
  function planOf(p) {
    var vendor = vendorOf(p)
    var tier = String(p && p.tierLabel ? p.tierLabel : "")
    var name = String(p && (p.providerName || p.name) ? (p.providerName || p.name) : "")
    if (vendor !== "" && name.toLowerCase().indexOf(vendor.toLowerCase()) >= 0) vendor = ""
    var parts = []
    if (vendor !== "") parts.push(vendor)
    if (tier !== "") parts.push(tier)
    return parts.join(" ")
  }

  // As contas Claude sao as que se revezam no trabalho; o resto e apoio. Entao
  // elas ficam sempre no bloco de cima, mesmo esgotadas: procurar a proxima
  // Claude no meio de uma lista misturada e o que a tabela existe para evitar.
  function vendorRank(p) {
    var id = String(p && (p.providerId || p.id) ? (p.providerId || p.id) : "")
    return (id === "claude" || id.indexOf("claude-") === 0) ? 0 : 1
  }

  // O limite de um modelo so ("Fable Weekly"), que nao manda na conta mas muda
  // o que da para fazer nela. Fica na linha de detalhe, com o nome do modelo.
  function scopedWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (!w.long || !w.scoped) continue
      if (!best || w.percent > best.percent) best = w
    }
    return best
  }

  readonly property var overviewRows: {
    var rows = []
    for (var i = 0; i < providers.length; i++) {
      var p = providers[i]
      var w = budgetWindow(p)
      var free = freeSpace(p)
      var ms = w ? resetMsFor(w) : -1
      var t = throttleWindow(p)
      var tFree = throttleFree(p)
      var blocked = tFree < usableFloor
      var sc = scopedWindow(p)
      rows.push({
        index: i,
        name: String(p.providerName || p.name || p.providerId || "?"),
        plan: planOf(p),
        vendorRank: vendorRank(p),
        // Os tres numeros do planejamento, cada um respondendo uma coisa:
        // a janela diz se da para comecar agora, a semana diz quanto sobra ate
        // a data, e o limite do modelo diz o que da para rodar nela.
        windowPercent: t ? Number(t.percent) : -1,
        windowResetMs: t ? resetMsFor(t) : -1,
        scopedLabel: sc ? String(sc.title) : "",
        scopedPercent: sc ? Number(sc.percent) : -1,
        // O numero e o prazo sao os do ORCAMENTO: e ele que se perde.
        percent: w ? Number(w.percent) : -1,
        resetMs: ms,
        free: free,
        // O freio vira aviso na linha, nao numero principal.
        blocked: blocked,
        throttleResetMs: t ? resetMsFor(t) : -1,
        // Grupo 0 disputa a vez. Fica de fora quem nao tem orcamento sobrando
        // e quem esta com a janela do momento cheia: as duas coisas impedem
        // aproveitar alguma coisa antes do reset, por motivos diferentes.
        group: (free >= usableFloor && !blocked) ? 0 : 1
      })
    }
    rows.sort(function (a, b) {
      if (a.vendorRank !== b.vendorRank) return a.vendorRank - b.vendorRank
      if (a.group !== b.group) return a.group - b.group
      // Sem data de reset nao ha urgencia: vai depois de quem tem prazo.
      var am = a.resetMs > 0 ? a.resetMs : Infinity
      var bm = b.resetMs > 0 ? b.resetMs : Infinity
      if (am !== bm) return am - bm
      return b.free - a.free
    })
    return rows
  }

  // So recomenda quem esta na disputa e tem prazo: sugerir uma conta sem data
  // de reset nao responde "use antes que vire".
  // A primeira Claude que da para usar. Se nenhuma der, a primeira de qualquer
  // fornecedor: quando as Claude acabaram, "use a Z.AI" e a resposta util, e
  // insistir numa Claude esgotada so porque ela e Claude nao ajuda ninguem.
  function recommendedIndex() {
    var rows = overviewRows
    var fallback = -1
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].group !== 0 || !(rows[i].resetMs > 0)) continue
      if (rows[i].vendorRank === 0) return i
      if (fallback < 0) fallback = i
    }
    return fallback
  }

  readonly property int recommended: recommendedIndex()

  readonly property string bestAccount: {
    var rows = overviewRows
    if (rows.length < 2 || recommended < 0) return ""
    return rows[recommended].name
  }

  readonly property string bestAccountIn: {
    var rows = overviewRows
    if (recommended < 0 || !(rows[recommended].resetMs > 0)) return ""
    return formatDuration(rows[recommended].resetMs)
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitButtonWidth
  implicitHeight: icon.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  // O icone sozinho dizia que existe uso; nao dizia o que fazer com ele. Com
  // varias contas a pergunta na barra e sempre a mesma -- qual pego agora --
  // e a resposta cabe em uma palavra ao lado do icone, sem abrir o painel.
  //
  // O nome so aparece quando ha o que recomendar: com uma conta so, ou com
  // todas apertadas, bestAccount fica vazio e o widget volta a ser o icone.
  Row {
    id: button
    anchors.fill: parent
    spacing: 0

    readonly property real implicitButtonWidth: icon.implicitWidth + (label.visible ? label.implicitWidth : 0)

    BarIconButton {
      id: icon
      bar: root.bar
      text: "󱚣"
      active: root.alarming
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) root.launchAgent()
        else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
        else root.toggle()
      }
    }

    WidgetButton {
      id: label
      visible: root.bestAccount !== "" && !root.vertical
      bar: root.bar
      text: root.bestAccount
      fontSize: Style.font.caption
      horizontalMargin: 4
      tooltipText: "Conta com folga cuja janela vira antes: use ou perca"
      onPressed: function() { root.toggle() }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  // icon, nao button: o id "button" agora e a Row da barra, e
                  // Row nao tem text. Quem carrega o glifo e o BarIconButton.
                  text: icon.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          //
          // Uma linha por conta em vez de uma aba por conta. A Row anterior
          // dividia a largura entre os provedores, entao com uma duzia deles
          // cada celula virava uma tira de poucos pixels com o nome cortado.
          // Empilhado, o numero de contas deixa de brigar com a legibilidade,
          // e a lista ordenada ja responde qual usar sem abrir mais nada.
          Column {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              // Com a data, o conselho se explica sozinho e da para conferir.
              text: root.bestAccount !== ""
                ? "CONTAS · use " + root.bestAccount + " · vence em " + root.bestAccountIn
                : "CONTAS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.overviewRows

              OverviewRow {
                required property var modelData
                required property int index

                width: providerSwitch.width
                row: modelData
                first: index === root.recommended
                current: modelData.index === root.providerIndex
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  // Uma conta na tabela de comparacao: nome, quanto falta para zerar, barra e
  // percentual. Clicar troca o detalhe mostrado abaixo, entao a tabela e o
  // seletor -- nao ha um segundo lugar para escolher a conta.
  component OverviewRow: Rectangle {
    id: overviewRow
    property var row: null
    property bool first: false
    property bool current: false

    // Vermelho e "nao da para usar agora", que vem do freio, e nao de uma
    // semana bem gasta: 92% de semanal com a janela livre ainda funciona.
    readonly property bool alarming: !!row && (row.blocked || row.percent >= 0.9)
    readonly property bool known: !!row && row.percent >= 0

    implicitHeight: overviewContent.implicitHeight + Style.space(10) * 2
    radius: Style.cornerRadius
    // O mesmo preenchimento que o resto do shell usa para "isto está
    // selecionado"; inventar um alpha aqui daria um destaque fora do tema.
    color: current ? Style.selectedFillFor(root.foreground) : "transparent"

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.cursorActive = true
        root.selectProvider(overviewRow.row.index)
      }
      onEntered: root.cursorActive = true
    }

    Column {
      id: overviewContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)

      Item {
        width: parent.width
        implicitHeight: Math.max(overviewName.implicitHeight, overviewValue.implicitHeight)

        Text {
          id: overviewName
          textFormat: Text.PlainText
          // A seta marca a recomendacao. Sem ela a ordenacao ainda esta certa,
          // mas exige que a pessoa saiba que a lista esta ordenada.
          // Nome e plano juntos: "Exato · Codex pro". Sem o plano, quatro
          // fornecedores lado a lado viram uma lista de apelidos.
          text: {
            if (!overviewRow.row) return ""
            var mark = overviewRow.first && root.bestAccount !== "" ? "→ " : ""
            var plan = overviewRow.row.plan
            return mark + overviewRow.row.name + (plan !== "" ? "  ·  " + plan : "")
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: overviewValue.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: overviewValue
          textFormat: Text.PlainText
          // Percentual e tempo juntos: um sem o outro nao decide nada.
          // O numero e o prazo sao os da semana, que e o que se perde. Quando a
          // janela de 5 horas esta cheia, a conta nao serve AGORA por mais
          // folga semanal que tenha, e isso precisa aparecer na linha: sem o
          // aviso, uma conta no fim da lista com 26% parece disponivel.
          // Aqui em cima fica so o prazo da semana, que e por onde a lista esta
          // ordenada; os percentuais desceram para a linha de detalhe. Repetir
          // o numero nos dois lugares so tirava espaco do nome da conta.
          text: {
            if (!overviewRow.known) return "—"
            if (overviewRow.row.blocked) {
              var t = overviewRow.row.throttleResetMs
              return t > 0 ? "cheia · volta em " + root.formatDuration(t) : "cheia agora"
            }
            var ms = overviewRow.row.resetMs
            return ms > 0 ? "vence em " + root.formatDuration(ms) : "sem prazo"
          }
          color: overviewRow.alarming ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // Os tres numeros do Akita, um do lado do outro: a janela de agora, a
      // semana, e o limite do modelo. Cada um responde uma pergunta diferente e
      // sozinho nenhum deles deixa planejar: a semana diz quanto sobra ate a
      // data, a janela diz se da para comecar agora, e o Fable diz o que da
      // para rodar. Some a parte que o fornecedor nao reporta, em vez de
      // mostrar um traco onde nunca vai haver numero.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: {
          if (!overviewRow.row) return ""
          var parts = []
          var wp = overviewRow.row.windowPercent
          if (wp >= 0) {
            var wms = overviewRow.row.windowResetMs
            parts.push("janela " + Math.round(wp * 100) + "%"
              + (wms > 0 ? " · " + root.formatDuration(wms) : ""))
          }
          var pc = overviewRow.row.percent
          if (pc >= 0) {
            var pms = overviewRow.row.resetMs
            parts.push("semana " + Math.round(pc * 100) + "%"
              + (pms > 0 ? " · " + root.formatDuration(pms) : ""))
          }
          if (overviewRow.row.scopedPercent >= 0) {
            // "Fable Weekly" vira "fable": a linha ja diz "semana" ao lado, e o
            // que falta saber aqui e de qual modelo e o limite.
            var name = overviewRow.row.scopedLabel.replace(/\s*weekly\s*$/i, "")
            parts.push(name.toLowerCase() + " " + Math.round(overviewRow.row.scopedPercent * 100) + "%")
          }
          return parts.join("   ·   ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Rectangle {
        width: parent.width
        height: Style.space(4)
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

        Rectangle {
          height: parent.height
          radius: parent.radius
          width: overviewRow.known
            ? Math.max(2, parent.width * Math.min(1, Math.max(0, overviewRow.row.percent)))
            : 0
          color: overviewRow.alarming ? root.urgent : root.foreground
        }
      }
    }
  }

  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
