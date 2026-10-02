// 實際 Go 版本紀錄 → Wails／WebView → 關閉確認，僅存在於 Smoke 建置。
window.runUpdateNoticeSmoke = async function () {
  const completed = [], wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  let latest = {}, notice;
  const stateHandler = window.handleNativeState, noticeHandler = window.handleUpdateComplete;
  window.handleNativeState = payload => { latest = Object.assign({}, latest, payload); stateHandler(payload); };
  window.handleUpdateComplete = payload => { notice = payload; noticeHandler(payload); };
  const post = (action, fields) => window.PhotoNativeBridge.post(Object.assign({action}, fields));
  async function until(test, label) {
    const start = performance.now();
    while (!test()) {
      if (performance.now() - start > 15000) throw new Error('更新摘要逾時：' + label);
      await wait(25);
    }
  }
  try {
    post('getState');
    await until(() => latest.styles?.length, '目錄就緒');
    for (const language of ['traditionalChinese', 'english', 'japanese', 'korean']) {
      post('setLanguage', {language});
      await until(() => latest.language === language, '切換語言');
      const blocker = document.createElement('dialog');
      document.body.appendChild(blocker); blocker.showModal(); notice = null;
      window.runtime.EventsEmit('filmdevelop:smoke-update-notice');
      await until(() => notice, '宿主傳送摘要');
      if (document.getElementById('updateCompleteDialog')) throw new Error('其他對話框尚未關閉卻顯示更新摘要');
      blocker.close(); blocker.remove();
      await until(() => document.getElementById('updateCompleteDialog')?.open, '關閉後重送');
      const dialog = document.getElementById('updateCompleteDialog');
      const body = dialog.querySelector('.update-complete-body');
      const notes = notice.notes;
      if (notes.releases.length !== 1 || !body.textContent.includes(notes.previousTag.slice(1).replace('-build-', ' build '))) throw new Error('未顯示上一個發布版本');
      for (const change of notes.releases[0].changes) {
        if (!body.textContent.includes(change.text[language]) || !body.textContent.includes(notes.labels[change.kind][language])) throw new Error('缺少翻譯或版本差異：' + language);
      }
      if (body.querySelectorAll('li').length !== notes.releases[0].changes.length || body.textContent.includes('Go 統一管理桌面介面')) throw new Error('仍顯示舊的泛用摘要');
      const rect = dialog.getBoundingClientRect();
      if (rect.top < 0 || rect.bottom > innerHeight + 1 || dialog.scrollWidth > dialog.clientWidth + 1) throw new Error('更新摘要超出視窗');
      dialog.querySelector('.prompt-dialog-actions [data-update-close]').click();
      await wait(1400);
      if (document.getElementById('updateCompleteDialog')) throw new Error('確認後又顯示同一摘要');
      completed.push('實際更新摘要、版本差異、延後顯示及確認：' + language);
    }
    post('setLanguage', {language:'traditionalChinese'});
    await until(() => latest.language === 'traditionalChinese', '還原語言');
    return completed;
  } finally {
    window.handleNativeState = stateHandler;
    window.handleUpdateComplete = noticeHandler;
  }
};
