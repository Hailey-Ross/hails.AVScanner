<?php

if (php_sapi_name() !== 'cli' && !defined('ALLOW_CONFIG_INCLUDE')) {
    http_response_code(403);
    exit('Forbidden');
}

define('DB_SERVER', 'localhost');
define('DB_USERNAME', 'YOUR-USER-NAME');
define('DB_PASSWORD', 'YOUR-PASSWORD-HERE');

define('ATTACHMENTS_DB_NAME', 'avscanner');
define('ATTACHMENTS_API_KEY', 'YOUR-SECURE-API-KEY');

?>
