(function ($) {
    $.su = $.su || {};
    $.su.CHAR = {
        PROTAL: {
            SUCCESS: '正常完了',
            FAILED: 'ログインできません。後でもう一度お試しください。',
            WELCOME: 'こんにちは！',
            PASSWORD: 'パスワード',
            LOGIN: 'ログイン',
            TERMS_OF_USE: '利用規約',
            ACCEPT_TERMS_OF_USE: '{termsOfUse} を確認のうえ同意しました',
            TERMS_OF_USE_ERROR: '確認のうえ「{acceptNote}」にチェックを入れてください。'
        },
        ERROR: {
            '00000001': 'この項目は必須です。',
            '00000002': '無効な形式です。',
            '00000003': '誤ったパスワードです。'
        }
    };
}(jQuery));