import Foundation

/// 注入网页的脚本。全部是「只读/旁路」性质：不改工作台的任何数据，不改业务逻辑。
enum Injected {
    static let keyName = "gt-lib-key-v1"
    /// 工作台页面所在域名（平台外壳里 iframe 的域）。放进 JS 字符串里，所以反斜杠写两个。
    static var hostRE = #"(^|\\.)codebuddy\\.work$"#

    /// 所有 frame（包括平台外壳里嵌着的工作台 iframe）、文档开始时执行。
    /// seedJSON：钥匙串里存的密钥（JSON 字符串字面量），没有则传 "null"。
    static func script(seedJSON: String) -> String {
        return #"""
        (function(){
          try {
            var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gt;
            if (!bridge) return;
            var isTop = (window === window.top);
            var KEY = "__KEYNAME__";
            var SEED = __SEED__;

            function post(o){ try { bridge.postMessage(o); } catch(e){} }

            /* ① 工作台页面所在 frame：记住访问码的密钥 ←→ 钥匙串 */
            if (!isTop && new RegExp("__HOSTRE__").test(location.hostname)) {
              try { if (SEED && !localStorage.getItem(KEY)) { localStorage.setItem(KEY, SEED); post({t:'restored'}); } } catch(e){}
              var rawSet = Storage.prototype.setItem, rawRem = Storage.prototype.removeItem;
              Storage.prototype.setItem = function(k, v){
                if (k === KEY && this === window.localStorage) post({t:'keySet', v:String(v)});
                return rawSet.apply(this, arguments);
              };
              Storage.prototype.removeItem = function(k){
                if (k === KEY && this === window.localStorage) post({t:'keyDel'});
                return rawRem.apply(this, arguments);
              };
              /* 心跳：告诉原生「现在是否空闲（没有未保存的改动、没在打字）」，原生据此决定能不能安全自动刷新 */
              setInterval(function(){
                var typing = false, dirty = false, loaded = false;
                try {
                  var ae = document.activeElement;
                  typing = !!(ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA') && String(ae.value || '').length > 0);
                  var ta = document.querySelector('textarea[data-draft="all"]');
                  if (ta && String(ta.value || '').length > 0) typing = true;
                  if (document.getElementById('uiDlg') || document.querySelector('.mask')) typing = true;
                  var s = window.saveState;
                  dirty = (s === 'pending' || s === 'saving' || s === 'error');
                  if (localStorage.getItem('gt-lib-pend-v1')) dirty = true;
                  loaded = (typeof window.DB === 'object');
                } catch(e){ dirty = true; }
                post({t:'beat', idle: !(typing || dirty), loaded: loaded});
              }, 3000);
            }

            /* ② 平台外壳（最外层）：隐藏「回 WorkBuddy 继续聊」等平台浮层，它们点了会跳出应用 */
            if (isTop) {
              var RE = /^(回 ?WorkBuddy 继续聊|前往 ?WorkBuddy|一键做同款|Continue in WorkBuddy|Go to WorkBuddy|Make the same)$/;
              var queued = false;
              function sweep(){
                queued = false;
                try {
                  var els = document.querySelectorAll('div,button,a,span,p');
                  for (var i = 0; i < els.length; i++) {
                    var el = els[i];
                    if (el.children.length > 2) continue;
                    var t = (el.textContent || '').replace(/\s+/g, ' ').trim();
                    if (t.length > 24 || !RE.test(t)) continue;
                    var n = el;
                    while (n && n !== document.body) {
                      if (getComputedStyle(n).position === 'fixed') { n.style.setProperty('display', 'none', 'important'); break; }
                      n = n.parentElement;
                    }
                  }
                } catch(e){}
              }
              function queue(){ if (!queued) { queued = true; requestAnimationFrame(sweep); } }
              function start(){
                try { new MutationObserver(queue).observe(document.documentElement, {childList:true, subtree:true}); } catch(e){}
                queue();
              }
              if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
            }
          } catch(e){}
        })();
        """#
        .replacingOccurrences(of: "__HOSTRE__", with: hostRE)
        .replacingOccurrences(of: "__KEYNAME__", with: keyName)
        .replacingOccurrences(of: "__SEED__", with: seedJSON)
    }

    /// 把字符串变成合法的 JS 字符串字面量（经 JSON 转义）。nil → "null"。
    static func jsLiteral(_ s: String?) -> String {
        guard let s = s else { return "null" }
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let j = String(data: d, encoding: .utf8), j.count >= 2 {
            return String(j.dropFirst().dropLast())
        }
        return "null"
    }
}
