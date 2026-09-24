(function () {
  'use strict';
  var catalog = window.PhotoLocalizationData;
  var language;
  var indices = { english: 0, japanese: 1, korean: 2 };
  var locales = { traditionalChinese: 'zh-Hant', english: 'en', japanese: 'ja', korean: 'ko' };
  function preference() {
    return (window.__appInfo && window.__appInfo.languagePreference) || localStorage.getItem('photoStyle.language') || 'automatic';
  }
  function resolve(value) {
    if (locales[value]) return value;
    var system = (window.__appInfo && window.__appInfo.systemLanguage) || navigator.language || 'zh-Hant';
    return /^en/i.test(system) ? 'english' : /^ja/i.test(system) ? 'japanese' : /^ko/i.test(system) ? 'korean' : 'traditionalChinese';
  }
  function locale(value) { return locales[resolve(value)]; }
  function regexEscape(value) { return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  var templates = Object.keys(catalog).filter(function (key) { return /\{\d+\}/.test(key); }).sort(function (a,b) { return b.replace(/\{\d+\}/g,'').length-a.replace(/\{\d+\}/g,'').length; }).map(function (key) {
    var order = [], offset = 0, pattern = '^';
    key.replace(/\{(\d+)\}/g, function (match, id, at) {
      pattern += regexEscape(key.slice(offset, at)) + '([\\s\\S]*?)'; order.push(Number(id)); offset = at + match.length;
    });
    return { key: key, regex: new RegExp(pattern + regexEscape(key.slice(offset)) + '$'), order: order };
  });
  // Only known built-in names and nested errors are translated; user arguments stay literal.
  var nestedArguments = {"以「{0}」為基礎儲存的自訂參數。": 0, "無法啟動：{0}": 0, "照片調整暫時無法儲存：{0}": 0, "無法還原模型目錄，請確認磁碟已連接或重新選擇。{0}": 0, "無法還原模型目錄，請重新選擇。{0}": 0, "無法讀取圖片：{0}": 0, "匯出失敗：{0}": 0, "無法記住這張照片：{0}": 0, "無法載入 AI 核心：{0}。{1}": 1, "MLX 分析失敗，照片未變更。{0}": 0, "無法讀取 MLX 模型：{0}": 0, "無法讀取照片目錄：{0}": 0, "無法刪除檔案：{0}": 0};
  function text(value, depth) {
    depth = depth || 0;
    if (value === undefined || value === null) return '';
    value = String(value);
    if (language === 'traditionalChinese') return value;
    var key = value.trim(), translated = catalog[key] && catalog[key][indices[language]];
    if (!translated) {
      for (var i = 0; i < templates.length; i++) {
        var item = templates[i], match = item.regex.exec(key);
        if (!match) continue;
        translated = catalog[item.key][indices[language]].replace(/\{(\d+)\}/g, function (_, id) { var argument = match[item.order.indexOf(Number(id)) + 1]; return depth < 4 && nestedArguments[item.key] === Number(id) ? text(argument, depth + 1) : argument; });
        break;
      }
    }
    return translated ? value.slice(0, value.indexOf(key)) + translated + value.slice(value.indexOf(key) + key.length) : value;
  }
  // Only used on compile-time HTML fragments. Dynamic names and prompts pass through escapeHtml unchanged.
  var staticKeys = Object.keys(catalog).filter(function (key) { return !/\{\d+\}/.test(key); }).sort(function (a,b) { return b.length-a.length; });
  var staticPattern = new RegExp(staticKeys.map(regexEscape).join('|'), 'g');
  function html(value) {
    if (language === 'traditionalChinese') return value;
    return value.replace(staticPattern, function (key) {
      return catalog[key][indices[language]].replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    });
  }
  function setLanguage(value) {
    language = resolve(value);
    document.documentElement.lang = locales[language];
    document.querySelectorAll('[data-l10n]').forEach(function (node) { node.textContent = text(node.dataset.l10n); });
    document.querySelectorAll('[data-l10n-aria]').forEach(function (node) { node.setAttribute('aria-label', text(node.dataset.l10nAria)); });
    document.querySelectorAll('[data-l10n-alt]').forEach(function (node) { node.alt = text(node.dataset.l10nAlt); });
  }
  window.PhotoL10n = { text: text, html: html, setLanguage: setLanguage, resolve: resolve, locale: locale, preference: preference };
  setLanguage(preference());
})();
