<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Тест веб-сервера</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
        h1 { color: #2e7d32; text-align: center; }
        .info { background: #f5f5f5; padding: 1rem; border-radius: 4px; margin: 1rem 0; }
        .status-ok { color: #2e7d32; font-weight: bold; }
        .status-no { color: #c62828; font-weight: bold; }
        a { color: #1976d2; }
    </style>
</head>
<body>
    <h1>✅ Веб-сервер работает</h1>
    <div class="info">
        <p><strong>Корень сайта:</strong> {{SITE_ROOT}}</p>
        <p><strong>Домен:</strong> {{SITE_DOMAIN}}</p>
        <p><strong>Веб-сервер:</strong> <span class="{{WEB_SERVER_CLASS}}">{{WEB_SERVER_NAME}}</span></p>
        <p><strong>PHP:</strong> <span class="{{PHP_CLASS}}">{{PHP_NAME}}</span></p>
    </div>
    {{PHP_LINK}}
    <p><small>Установлено: <a href="https://github.com/saym101/-LAMP-Apache-Angie-PHP-" target="_blank">lamp.sh v{{SCRIPT_VERSION}}</a></small></p>
</body>
</html>
