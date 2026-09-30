import AVFoundation
import Foundation
import UIKit
import WebKit

/// The wrapped browser.
///
/// Most of this file exists because of specific, documented failures in the app
/// we are cloning. Each one is annotated with the symptom it prevents — none of
/// this is defensive boilerplate.
final class WrappedWebViewController: UIViewController {

    private let session: WebSession
    private let startURL: URL
    private let engineSource: String
    private let bundleRaw: Data
    private let settings: [String: Bool]
    /// The username Instagram shows for the signed-in account.
    private let onUsername: (String) -> Void

    private var webView: WKWebView!
    private var restorationState: Data?
    fileprivate var lastExternalOpen = Date.distantPast

    init(session: WebSession,
         startURL: URL,
         dataStore: WKWebsiteDataStore,
         engineSource: String,
         bundleRaw: Data,
         settings: [String: Bool],
         onUsername: @escaping (String) -> Void) {
        self.session = session
        self.startURL = startURL
        self.engineSource = engineSource
        self.bundleRaw = bundleRaw
        self.settings = settings
        self.onUsername = onUsername
        super.init(nibName: nil, bundle: nil)
        configure(dataStore: dataStore)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: - Configuration

    private func configure(dataStore: WKWebsiteDataStore) {
        let controller = WKUserContentController()

        // The engine runs at documentStart so blocking CSS lands before first
        // paint. Injecting at documentEnd would let a Reel render and then
        // vanish, and that flicker is what makes a blocker feel broken.
        let config = engineConfigJSON()
        //
        // The engine reads its config once, synchronously, and keeps it in a
        // closure. So the global is deleted before any page script runs;
        // otherwise the page could read the user's settings and fingerprint
        // the wrapper.
        let bootstrap = """
        window.__NOSCROLL_CONFIG = \(config);
        try {
        \(engineSource)
        } finally {
          try { delete window.__NOSCROLL_CONFIG; } catch (e) {}
        }
        """
        controller.addUserScript(WKUserScript(source: bootstrap,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(BridgeHandler(onUsername), name: "noscroll")

        // Rules are CSS selectors and cannot find a boundary by its text, so
        // the end of Instagram's followed feed is handled by a script of our own.
        // It shares the "Hide Ads & Suggested" switch.
        if session.service == "instagram", settings["instagram.suggested-posts"] ?? true {
            controller.addUserScript(WKUserScript(source: Self.instagramFeedEndJS,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
        if session.service == "instagram" {
            controller.addUserScript(WKUserScript(source: Self.instagramAccountJS,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: Self.instagramAppBannerJS,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
        // /explore/ is where Instagram's search box lives, so it is allowed
        // through; only its recommendation grid is hidden. Shares the "Block
        // Explore" switch.
        if session.service == "instagram", settings["instagram.explore-route"] ?? true {
            controller.addUserScript(WKUserScript(source: Self.instagramExploreJS,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }
        // One reel or post at a time: locks vertical scrolling in the reel
        // viewer, including one opened from a DM, which plays in an overlay
        // that never changes the URL. Drives the "One video at a time" switch.
        if session.service == "instagram", settings["instagram.isolated-player"] ?? true {
            controller.addUserScript(WKUserScript(source: Self.instagramReelLockJS,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }

        // A fullscreen video carries on in picture in picture when the app is
        // left, which YouTube's page would otherwise undo.
        if session.service == "youtube" {
            controller.addUserScript(WKUserScript(source: Self.youtubePictureInPictureJS,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        }

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = controller
        cfg.websiteDataStore = dataStore

        // Without these, video plays fullscreen-only and is silent unless the
        // ringer is on — a specific, repeated complaint about SocialLite.
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Apple 2.5.6: WKWebView only. We use the stock mobile user agent
        // unmodified — a custom UA is a fingerprint that raises the rate of
        // "suspicious login attempt" checkpoints against our users' accounts.
        //
        // Exception: X. Its site spots the embedded-browser UA and redirects
        // to x-safari-https://, which only Safari can open, leaving a blank
        // page. For X alone the UA reads as Mobile Safari's. Not applied
        // elsewhere: YouTube serves different markup to Safari, and the rules
        // are written against what the embedded browser receives.
        if session.service == "x" {
            cfg.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        }
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            // Content scrolling up under the status bar fades out rather than
            // meeting a hard edge. The obscured inset it fades within is kept
            // in step with the status bar in updateObscuredInsets().
            webView.scrollView.topEdgeEffect.style = .soft
        }
    }

    /// iOS 26+: the web view runs under the status bar (see WebScreen), and
    /// this tells WebKit that strip is covered, so the sites' fixed and sticky
    /// headers are kept below it and their backgrounds extend underneath.
    /// Measured from where the web view actually sits in the window, not
    /// assumed. The bottom is deliberately left uncovered (see below).
    ///
    /// The scroll view's insets must match. The covered strips shrink the
    /// page's visible area, but the scroll limits come from contentInset: left
    /// at 0, dragging back to the top stopped with the page's first 62 pt
    /// still hidden behind the header, cutting Instagram's stories row in
    /// half. Automatic inset adjustment stays off, so this is the only place
    /// the insets are applied.
    private func updateObscuredInsets() {
        guard #available(iOS 26.0, *), let window = view.window else { return }
        let frame = view.convert(view.bounds, to: window)
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        let top = max(0, safe.minY - frame.minY)
        // The bottom is never covered: that shrinks every page to end above
        // the home indicator, leaving a strip nothing scrolls behind.
        let bottom: CGFloat = 0
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if webView.obscuredContentInsets != insets {
            webView.obscuredContentInsets = insets
        }
        let scrollView = webView.scrollView
        if scrollView.contentInset.top != top || scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.top = top
            scrollView.contentInset.bottom = bottom
            scrollView.verticalScrollIndicatorInsets.top = top
            scrollView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateObscuredInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateObscuredInsets()
    }

    private func engineConfigJSON() -> String {
        let bundleJSON = String(data: bundleRaw, encoding: .utf8) ?? "{}"
        let settingsJSON = (try? JSONSerialization.data(withJSONObject: settings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        { "bundle": \(bundleJSON), "settings": \(settingsJSON) }
        """
    }

    /// Ends Instagram's home feed at "You're all caught up".
    ///
    /// Past that notice Instagram appends "Suggested Posts" indefinitely. This
    /// keeps the notice (and its "View older posts" link) and hides everything
    /// after it in the feed, including the sentinel that triggers loading more,
    /// so the page simply ends there. Nodes are hidden, never removed: removing
    /// nodes React owns crashes the feed and jumps the user back to the top.
    /// English-only for now: the boundary is found by its text.
    static let instagramFeedEndJS = #"""
    (() => {
      if (!/(^|\.)instagram\.com$/i.test(location.hostname)) return;
      const CAUGHT_UP = /^You[’']re all caught up$/i;
      const SUGGESTED = /^Suggested (posts|for you)$/i;
      let marker = null;

      const findText = (root, re) => {
        const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let t;
        while ((t = w.nextNode())) if (re.test(t.textContent.trim())) return t.parentElement;
        return null;
      };
      const hide = el => {
        if (el.style.getPropertyValue('display') !== 'none') el.style.setProperty('display', 'none', 'important');
      };

      function sweep() {
        if (location.pathname !== '/') return;
        const main = document.querySelector('main');
        if (!main) return;
        if (!marker || !marker.isConnected || !main.contains(marker)) marker = findText(main, CAUGHT_UP);
        if (!marker) return;
        const header = findText(main, SUGGESTED);

        // The notice's own block: the largest ancestor that holds no post and
        // not the "Suggested Posts" heading.
        let block = marker;
        while (block.parentElement && block.parentElement !== main) {
          const p = block.parentElement;
          if (p.querySelector('article') || (header && p.contains(header))) break;
          block = p;
        }
        // Everything after the block, at every level up to <main>, is past the
        // end of the followed feed.
        for (let el = block; el && el !== main; el = el.parentElement) {
          for (let s = el.nextElementSibling; s; s = s.nextElementSibling) hide(s);
        }
      }

      let queued = false;
      const schedule = () => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; sweep(); }, 50);
      };
      const start = () => {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        schedule();
      };
      if (document.documentElement) start();
      else document.addEventListener('readystatechange', start, { once: true });
    })();
    """#

    /// Reports the signed-in username so the account switcher can show it.
    ///
    /// Read from the tab bar (the fixed layer holding the Home and Messages
    /// links), whose remaining link is the user's own profile. Sent only when
    /// it changes. Nothing else is read.
    static let instagramAccountJS = #"""
    (() => {
      if (!/(^|\.)instagram\.com$/i.test(location.hostname)) return;
      const RESERVED = /^\/(explore|reels?|direct|accounts|p|stories)\//;
      let reported = '';
      const check = () => {
        const bar = [...document.querySelectorAll('a[href="/direct/inbox/"]')]
          .map(a => { for (let e = a; e && e !== document.body; e = e.parentElement)
                        if (getComputedStyle(e).position === 'fixed') return e; return null; })
          .find(e => e && e.querySelector('a[href="/"]'));
        if (!bar) return;
        const own = [...bar.querySelectorAll('a[href]')].map(a => a.getAttribute('href'))
          .find(h => /^\/[A-Za-z0-9._]{1,30}\/$/.test(h) && !RESERVED.test(h));
        const name = own ? own.slice(1, -1) : '';
        if (!name || name === reported) return;
        reported = name;
        window.webkit?.messageHandlers?.noscroll?.postMessage({ type: 'account', username: name });
      };
      check();
      setInterval(check, 2000);
    })();
    """#

    /// Hides Instagram's "Use the app" banner, the strip it pins above the tab
    /// bar to push the native app.
    ///
    /// Found by its text (English only), then hidden at its nearest fixed
    /// ancestor, which is the banner's own layer, so nothing else pinned to
    /// the screen (the tab bar) is touched. Runs inside the mutation callback,
    /// before the next paint, so the banner never flashes. Hidden, not removed.
    static let instagramAppBannerJS = #"""
    (() => {
      if (!/(^|\.)instagram\.com$/i.test(location.hostname)) return;
      const TEXT = /^(use|get) the app$/i;

      const hideBannerIn = root => {
        if (!root || !/the app/i.test(root.textContent || '')) return;
        const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let t;
        while ((t = w.nextNode())) {
          if (!TEXT.test(t.textContent.trim())) continue;
          for (let e = t.parentElement; e && e !== document.body; e = e.parentElement) {
            if (getComputedStyle(e).position === 'fixed') {
              // Banner-sized only: the same words in a DM could sit inside a
              // full-screen fixed layer, which must never be hidden.
              if (e.getBoundingClientRect().height <= 120) e.style.setProperty('display', 'none', 'important');
              break;
            }
          }
        }
      };

      const start = () => {
        new MutationObserver(records => {
          for (const r of records) {
            if (r.type === 'characterData') hideBannerIn(r.target.parentElement);
            for (const n of r.addedNodes) hideBannerIn(n.nodeType === 1 ? n : n.parentElement);
          }
        }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
        hideBannerIn(document.body);
      };
      if (document.documentElement) start();
      else document.addEventListener('readystatechange', start, { once: true });
    })();
    """#

    /// Keeps Instagram's search box on /explore/ and hides the grid below it.
    ///
    /// The grid is found from a post tile: the largest container around it that
    /// does not also hold the search box. It stays hidden while the search
    /// overlay (/explore/search/…) is open over it, and is shown again only
    /// when the user leaves Explore. Hidden, never removed.
    static let instagramExploreJS = #"""
    (() => {
      if (!/(^|\.)instagram\.com$/i.test(location.hostname)) return;
      const EXPLORE = /^\/explore\/?$/;
      const IN_EXPLORE = /^\/explore(\/search)?(\/|$)/;
      const TILE = 'a[href^="/p/"], a[href^="/reel/"]';
      const hidden = new Set();

      // No flash of the grid: the sweep below only runs after the grid has
      // been added, so before that a stylesheet already hides post tiles on
      // /explore/. It keys off an attribute on <html> that is updated the
      // moment the URL changes, so the rule is in force before the grid is
      // first painted. Search results (/explore/search/…) are not affected.
      const PAGE_ATTR = 'data-noscroll-explore-page';
      // Leaving Explore: Instagram keeps the old page on screen for a moment
      // while the next one renders, so un-hiding the grid on the URL change
      // flashed it. Everything stays hidden until Instagram has removed the
      // grid; if it is still attached after LINGER_MS (a reused element), it
      // is shown again so it can never hide another page's content.
      const LINGER_MS = 1000;
      let leftAt = 0;
      const gridStillMounted = () => [...hidden].some(el => el.isConnected);
      // ROOT_ATTR is set on /explore/ itself only (not the search overlay, not
      // while leaving). It hides everything on the page except the search box:
      // the grid, and also the loading spinner shown before the grid arrives,
      // which the tile rule can't catch. Written for either layout: search box
      // inside <main> (hide main's other parts) or outside it (hide all of main).
      const ROOT_ATTR = 'data-noscroll-explore-root';
      const mark = () => {
        const html = document.documentElement;
        if (!html) return;
        html.toggleAttribute(ROOT_ATTR, EXPLORE.test(location.pathname));
        if (EXPLORE.test(location.pathname)) { leftAt = 0; html.setAttribute(PAGE_ATTR, ''); return; }
        // Leaving for another page: keep tiles hidden while the old grid is
        // still on screen. Not on search pages: their results are post tiles
        // the user asked for, and the grid underneath is already hidden inline.
        if (!IN_EXPLORE.test(location.pathname) && gridStillMounted()) { if (!leftAt) leftAt = Date.now(); return; }
        html.removeAttribute(PAGE_ATTR);
      };
      const preHide = document.createElement('style');
      preHide.textContent = `html[${PAGE_ATTR}] main :is(a[href^="/p/"], a[href^="/reel/"]) { visibility: hidden !important; }
        html[${ROOT_ATTR}] main:has(input[type="search"]) > :not(:has(input[type="search"])) { visibility: hidden !important; }
        html[${ROOT_ATTR}] main:not(:has(input[type="search"])) > * { visibility: hidden !important; }`;
      const installPreHide = () => {
        if (!preHide.isConnected) (document.head || document.documentElement)?.appendChild(preHide);
        mark();
      };
      for (const method of ['pushState', 'replaceState']) {
        const original = history[method];
        history[method] = function (...args) {
          const result = original.apply(this, args);
          mark();
          return result;
        };
      }
      addEventListener('popstate', mark);
      installPreHide();

      const hide = el => {
        el.style.setProperty('display', 'none', 'important');
        hidden.add(el);
      };
      const restore = () => {
        for (const el of hidden) {
          el.style.removeProperty('display');
          el.removeAttribute('data-noscroll-explore');
        }
        hidden.clear();
      };

      // Instagram's search overlay draws its list above the bottom tab bar, so
      // no other tab can be reached until Cancel is tapped. While it is open
      // the bar (the fixed layer holding the Home and Messages links) is raised
      // above the list, and the page gets room so the last row isn't hidden.
      let searchStyle = null;
      const liftTabBar = on => {
        if (!on) { searchStyle?.remove(); searchStyle = null; return; }
        const bar = [...document.querySelectorAll('a[href="/direct/inbox/"]')]
          .map(a => { for (let e = a; e && e !== document.body; e = e.parentElement)
                        if (getComputedStyle(e).position === 'fixed') return e; return null; })
          .find(e => e && e.querySelector('a[href="/"]'));
        if (!bar) return;
        bar.setAttribute('data-noscroll-tabbar', '');
        if (!searchStyle) {
          searchStyle = document.createElement('style');
          searchStyle.textContent = '[data-noscroll-tabbar] { z-index: 1000 !important; }'
            + ' body { padding-bottom: 96px !important; }';
          document.documentElement.appendChild(searchStyle);
        }
      };

      function sweep() {
        const path = location.pathname;
        const searching = /^\/explore\/search(\/|$)/.test(path);
        liftTabBar(searching);
        if (!IN_EXPLORE.test(path)) {
          // Forget grids Instagram has already removed; show any it kept
          // (after LINGER_MS) rather than leave them hidden on another page.
          for (const el of hidden) if (!el.isConnected) hidden.delete(el);
          if (hidden.size && Date.now() - leftAt > LINGER_MS) restore();
          if (!hidden.size) document.documentElement.removeAttribute(PAGE_ATTR);
          return;
        }
        if (!EXPLORE.test(path)) return; // search overlay: leave the grid as it is
        const main = document.querySelector('main');
        if (!main) return;
        const search = document.querySelector('input[type="search"]');
        for (const tile of main.querySelectorAll(TILE)) {
          if (tile.closest('[data-noscroll-explore]')) continue;
          let grid = tile;
          while (grid.parentElement && grid.parentElement !== main && !(search && grid.parentElement.contains(search))) {
            grid = grid.parentElement;
          }
          grid.setAttribute('data-noscroll-explore', '');
          hide(grid);
        }
      }

      let queued = false;
      const schedule = () => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; sweep(); }, 50);
      };
      const start = () => {
        // Observer callbacks run before the next paint, so re-checking the
        // stylesheet and the URL here (both cheap) closes any remaining gap.
        new MutationObserver(() => { installPreHide(); schedule(); })
          .observe(document.documentElement, { childList: true, subtree: true });
        addEventListener('popstate', schedule);
        setInterval(schedule, 500);
        schedule();
      };
      if (document.documentElement) start();
      else document.addEventListener('readystatechange', start, { once: true });
    })();
    """#

    /// Pins any reel viewer to the reel the user opened.
    ///
    /// Instagram's viewer (in DMs it overlays the thread without a URL change)
    /// is a vertically snapping scroller that preloads the next reels. When one
    /// appears it is locked where it opened: user scrolling is switched off and
    /// any programmatic advance, such as autoplay-next, is undone. Nodes are
    /// only restyled, never removed.
    static let instagramReelLockJS = #"""
    (() => {
      if (!/(^|\.)instagram\.com$/i.test(location.hostname)) return;
      const locked = new WeakSet();

      const snapScrollerOf = video => {
        for (let el = video.parentElement, i = 0; el && el !== document.body && i < 16; el = el.parentElement, i++) {
          const cs = getComputedStyle(el);
          if (cs.scrollSnapType.startsWith('y') && el.scrollHeight > el.clientHeight) return el;
        }
        return null;
      };

      // Instagram may still be scrolling the viewer to the tapped reel just
      // after it mounts; the pinned position follows it until this settles.
      const SETTLE_MS = 400;
      const lock = el => {
        locked.add(el);
        const opened = performance.now();
        let top = el.scrollTop;
        el.style.setProperty('overflow-y', 'hidden', 'important');
        el.style.setProperty('overscroll-behavior', 'none', 'important');
        el.addEventListener('scroll', () => {
          if (performance.now() - opened < SETTLE_MS) { top = el.scrollTop; return; }
          if (Math.abs(el.scrollTop - top) > 1) el.scrollTop = top;
        }, { passive: true });
      };

      // A single post or reel page (/p/…, /reel/…), e.g. opened from a DM:
      // vertical scrolling is switched off so "more posts" below can't be
      // reached. Taps and sideways scrolling (photo carousels) are untouched,
      // and nothing navigates away. Everything is restored on leaving the page,
      // including scrollers of the chat underneath.
      const SINGLE_ITEM = /^\/(p|reel)\/[^/]+/;
      const pageLocked = new Map(); // element → its previous inline overflow-y
      let pageStyle = null;

      const lockPage = () => {
        if (!pageStyle) {
          pageStyle = document.createElement('style');
          pageStyle.textContent = 'html, body { overflow: hidden !important; overscroll-behavior: none !important; }';
          document.documentElement.appendChild(pageStyle);
        }
        for (const el of document.querySelectorAll('body *')) {
          if (pageLocked.has(el) || el.scrollHeight <= el.clientHeight + 1) continue;
          if (!/(auto|scroll)/.test(getComputedStyle(el).overflowY)) continue;
          pageLocked.set(el, el.style.getPropertyValue('overflow-y'));
          el.style.setProperty('overflow-y', 'hidden', 'important');
        }
      };

      const unlockPage = () => {
        pageStyle?.remove();
        pageStyle = null;
        for (const [el, previous] of pageLocked) {
          if (previous) el.style.setProperty('overflow-y', previous);
          else el.style.removeProperty('overflow-y');
        }
        pageLocked.clear();
      };

      function sweep() {
        for (const video of document.querySelectorAll('video')) {
          const scroller = snapScrollerOf(video);
          if (scroller && !locked.has(scroller)) lock(scroller);
        }
        if (SINGLE_ITEM.test(location.pathname)) lockPage();
        else if (pageStyle || pageLocked.size) unlockPage();
      }

      let queued = false;
      const schedule = () => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; sweep(); }, 50);
      };
      const start = () => {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        // In-app navigation changes the URL without a page load; this catches
        // leaving a post even if the DOM happens not to change.
        addEventListener('popstate', schedule);
        setInterval(schedule, 500);
        schedule();
      };
      if (document.documentElement) start();
      else document.addEventListener('readystatechange', start, { once: true });
    })();
    """#

    /// Lets a fullscreen YouTube video carry on in picture in picture when
    /// the app is left (iOS starts it on its own). YouTube stops it two ways,
    /// both answered here before its own code runs:
    ///  - it pauses whenever the page is hidden, so the page stays "visible";
    ///  - as fullscreen gives way to picture in picture it calls
    ///    webkitExitFullscreen() to tidy up, which ends picture in picture and
    ///    pauses; that call is ignored while picture in picture is showing.
    static let youtubePictureInPictureJS = #"""
    (() => {
      if (!/(^|\.)youtube\.com$/i.test(location.hostname)) return;
      const exitFullscreen = HTMLVideoElement.prototype.webkitExitFullscreen;
      HTMLVideoElement.prototype.webkitExitFullscreen = function () {
        if (this.webkitPresentationMode === 'picture-in-picture') return;
        return exitFullscreen.apply(this, arguments);
      };
      const visible = { hidden: false, webkitHidden: false, visibilityState: 'visible', webkitVisibilityState: 'visible' };
      for (const [key, value] of Object.entries(visible)) {
        Object.defineProperty(Document.prototype, key, { get: () => value, configurable: true });
      }
      const swallow = (e) => e.stopImmediatePropagation();
      for (const type of ['visibilitychange', 'webkitvisibilitychange']) {
        window.addEventListener(type, swallow, true);
        document.addEventListener(type, swallow, true);
      }
    })();
    """#

    // MARK: - Lifecycle

    override func loadView() { view = webView }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAudioSession()
        restoreOrLoad()

        NotificationCenter.default.addObserver(
            self, selector: #selector(saveState),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    /// Closing the service (the Home button) saves where it was left, for the
    /// services that reopen there. Loads save on their own, but in-page
    /// navigation doesn't, so without this they reopened on the page before.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveState()
    }

    /// Video that plays silently unless the ringer is on is an audio-session
    /// problem, not a WebKit one.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// iOS reaps the WebView process under memory pressure. Without restoration,
    /// switching to an authenticator app during 2FA and coming back produces a
    /// white screen and forces a restart — which blocks login entirely. That is
    /// a real, reported SocialLite bug and it is the single worst one, because
    /// the user cannot get past it.
    private static let opensOnHome: Set<String> = ["instagram", "youtube"]

    private func restoreOrLoad() {
        // Instagram and YouTube always open on their home page, not wherever
        // they were left (a DM, a video), whether closed with the Home button
        // or after the app was quit. The in-memory state above still restores
        // a page the system unloaded mid-session, e.g. during a 2FA app switch.
        if restorationState == nil, Self.opensOnHome.contains(session.service) {
            webView.load(URLRequest(url: homeURL()))
            return
        }
        if let state = restorationState ?? savedStateForThisService() {
            webView.interactionState = state
            return
        }
        webView.load(URLRequest(url: homeURL()))
    }

    /// The saved page, but only if it belongs to this service (or its sign-in
    /// pages, so a 2FA hand-off to an authenticator app survives). A state
    /// saved without its URL (older builds), or showing another service's
    /// site, is discarded so the service opens on its own home page instead.
    private func savedStateForThisService() -> Data? {
        let defaults = UserDefaults.standard
        guard let state = defaults.data(forKey: stateKey) else { return nil }
        if let saved = defaults.string(forKey: stateURLKey), isTrustedHost(URL(string: saved)?.host) {
            return state
        }
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: stateURLKey)
        return nil
    }

    /// Driven by the floating menu's Refresh item. A page that failed or never
    /// loaded has nothing to reload, so fall back to the service's home.
    func reload() {
        if webView.url == nil {
            webView.load(URLRequest(url: homeURL()))
        } else {
            webView.reload()
        }
    }

    /// The video being watched: playing, with sound. Muted ones are the
    /// feed's hover previews.
    private static let watchedVideoJS = """
    [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && !v.muted
      && v.webkitSupportsPresentationMode?.('picture-in-picture'))
    """

    private static let pictureInPictureVideoJS = """
    [...document.querySelectorAll('video')].find(v => v.webkitPresentationMode === 'picture-in-picture')
    """

    enum PictureInPictureState { case unavailable, available, active }

    /// What the floating menu offers: YouTube only, starting picture in
    /// picture while a video is being watched, or ending it while one shows.
    func pictureInPictureState() async -> PictureInPictureState {
        guard session.service == "youtube" else { return .unavailable }
        let js = "(\(Self.pictureInPictureVideoJS)) ? 'active' : (\(Self.watchedVideoJS)) ? 'available' : ''"
        switch try? await webView.evaluateJavaScript(js) as? String {
        case "active": return .active
        case "available": return .available
        default: return .unavailable
        }
    }

    /// Driven by the floating menu's picture-in-picture item: ends picture in
    /// picture if a video is showing in it, otherwise starts it.
    func togglePictureInPicture() {
        webView.evaluateJavaScript("""
        (() => {
          const shown = \(Self.pictureInPictureVideoJS);
          if (shown) { shown.webkitSetPresentationMode('inline'); return; }
          const v = \(Self.watchedVideoJS);
          if (v) v.webkitSetPresentationMode('picture-in-picture');
        })();
        """)
    }

    private var stateKey: String { "noscroll.state.\(session.id.uuidString)" }

    private var stateURLKey: String { stateKey + ".url" }

    /// Saved only while showing this service's own site or its sign-in pages,
    /// together with that URL, so another service's page can never become the
    /// page this service reopens on.
    @objc private func saveState() {
        guard let url = webView.url, isTrustedHost(url.host),
              let state = webView.interactionState as? Data else { return }
        restorationState = state
        UserDefaults.standard.set(state, forKey: stateKey)
        UserDefaults.standard.set(url.absoluteString, forKey: stateURLKey)
    }

    /// Supplied by the caller from the service definition. It used to be a
    /// switch over two hardcoded cases with `default: instagram`, which sent
    /// all six other services to Instagram.
    private func homeURL() -> URL { startURL }
}

// MARK: - Navigation

extension WrappedWebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }

        // Cancel app-scheme navigations. The sites try hard to hand off to
        // their native apps (instagram://, vnd.youtube://, x-safari-https://);
        // following those links would throw the user out of NoScroll mid-flow.
        if let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.cancel); return
        }

        // There is no address bar, so a page loaded here is indistinguishable
        // from the real service: a DM'd link to a fake login page would be a
        // perfect phish. Only first-party hosts may load as the top-level page;
        // anything else opens in Safari, where the user can see the domain.
        // Subframes are left alone — they are embedded by the trusted page.
        // Server redirects re-enter this method, so a link shim such as
        // l.instagram.com that bounces to an outside site is caught too.
        if navigationAction.targetFrame?.isMainFrame ?? true,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           !isTrustedHost(url.host) {
            openExternally(url)
            decisionHandler(.cancel); return
        }

        decisionHandler(.allow)
    }

    /// True for this service's own sites (see AppState.serviceDomains).
    func isServiceHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let domains = AppState.serviceDomains[session.service] ?? []
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// This service's sites, plus the single sign-on pages any of them may
    /// hand off to. Google sets session cookies on its country domains
    /// (google.co.uk, …) during sign-in, so those are matched by pattern.
    func isTrustedHost(_ host: String?) -> Bool {
        if isServiceHost(host) { return true }
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if ["google.com", "appleid.apple.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        return host.range(of: #"(^|\.)google(\.com?)?\.[a-z]{2}$"#,
                          options: .regularExpression) != nil
    }


    /// Debounced so a page that redirects outward in a loop cannot spam Safari.
    private func openExternally(_ url: URL) {
        let now = Date()
        guard now.timeIntervalSince(lastExternalOpen) > 1 else { return }
        lastExternalOpen = now
        UIApplication.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        saveState()
    }

    /// A crashed WebView must recover, not sit blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        restoreOrLoad()
    }
}

// MARK: - UI delegate

/// WKUIDelegate is MANDATORY, not optional. Without these callbacks, `<input
/// type=file>` pickers and getUserMedia fail *silently* — which is exactly the
/// "can't upload a video to posts/story" complaint against SocialLite. The
/// feature looks broken rather than unsupported.
extension WrappedWebViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Prompt the user via the system permission sheet rather than silently
        // denying. Requires NSCameraUsageDescription / NSMicrophoneUsageDescription.
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank inside a wrapper should navigate in place, not vanish.
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - Bridge

/// The one message the page sends the app: the signed-in username, from
/// instagramAccountJS.
private final class BridgeHandler: NSObject, WKScriptMessageHandler {
    private let onUsername: (String) -> Void
    init(_ onUsername: @escaping (String) -> Void) { self.onUsername = onUsername }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Only a plausible Instagram username is accepted from the page.
        guard let dict = message.body as? [String: Any],
              dict["type"] as? String == "account",
              let name = dict["username"] as? String,
              name.range(of: #"^[A-Za-z0-9._]{1,30}$"#, options: .regularExpression) != nil
        else { return }
        onUsername(name)
    }
}
