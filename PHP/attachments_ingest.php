<?php
declare(strict_types=1);

header('Content-Type: text/plain; charset=utf-8');

define('ALLOW_CONFIG_INCLUDE', true);
require_once '/usr/path/to/your/secure/config.php';

function utc_now_string(): string
{
    return gmdate('Y-m-d H:i:s') . ' UTC';
}

function respond_and_exit(string $message, int $httpCode = 200): void
{
    http_response_code($httpCode);
    echo $message . ' | ' . utc_now_string();
    exit;
}

function normalize_uuid($value): string
{
    if (!is_string($value)) return '';

    $value = trim(strtolower($value));

    if (!preg_match('/^[0-9a-f-]{36}$/', $value)) return '';

    return $value;
}

function normalize_string($value, int $maxLength = 255): string
{
    if (!is_string($value)) return '';

    $value = trim($value);
    $value = preg_replace('/\s+/u', ' ', $value) ?? '';

    if (function_exists('mb_substr')) {
        return mb_substr($value, 0, $maxLength, 'UTF-8');
    }

    return substr($value, 0, $maxLength);
}

$rawInput = file_get_contents('php://input');
if ($rawInput === false || trim($rawInput) === '') {
    respond_and_exit('No request body received', 400);
}

$payload = json_decode($rawInput, true);
if (!is_array($payload)) {
    respond_and_exit('Invalid JSON payload', 400);
}

$apiKey = $payload['api_key'] ?? '';
if (!is_string($apiKey) || !hash_equals(ATTACHMENTS_API_KEY, $apiKey)) {
    respond_and_exit('Invalid API key', 403);
}

$records = $payload['records'] ?? null;
if (!is_array($records) || empty($records)) {
    respond_and_exit('No records supplied', 400);
}

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);

$mysqli = new mysqli(DB_SERVER, DB_USERNAME, DB_PASSWORD, ATTACHMENTS_DB_NAME);
if ($mysqli->connect_errno) {
    respond_and_exit('Database connection failed: ' . $mysqli->connect_error, 500);
}

$mysqli->set_charset('utf8mb4');

$insertStagingStmt = $mysqli->prepare("
    INSERT INTO ingest_staging (
        avatar_uuid, avatar_name, object_name, object_desc, attach_point, received_utc
    ) VALUES (UNHEX(REPLACE(?, '-', '')), ?, ?, ?, ?, UTC_TIMESTAMP())
");

if (!$insertStagingStmt) {
    respond_and_exit('Statement preparation failed: ' . $mysqli->error, 500);
}

$received = 0;
$invalid = 0;

try {
    // Phase 1: land the raw rows in ingest_staging and commit immediately.
    // Once committed the data is safe even if processing below fails.
    $mysqli->begin_transaction();

    foreach ($records as $record) {

        if (!is_array($record)) {
            $invalid++;
            continue;
        }

        $avatarUuid = normalize_uuid($record['avatar_uuid'] ?? '');
        $avatarName = normalize_string($record['avatar_name'] ?? '');
        $attachmentUuid = normalize_uuid($record['attachment_uuid'] ?? '');
        $attachmentName = normalize_string($record['attachment_name'] ?? '');
        $attachmentDesc = normalize_string($record['attachment_desc'] ?? '');
        $attachedPoint = max(0, min(255, (int)($record['attached_point'] ?? 0)));

        // attachment_uuid is validated to prove the record is well-formed,
        // but not stored: it changes on every relog so it carries no identity
        if ($avatarUuid === '' || $avatarName === '' || $attachmentUuid === '' || $attachmentName === '') {
            $invalid++;
            continue;
        }

        $insertStagingStmt->bind_param(
            'ssssi',
            $avatarUuid,
            $avatarName,
            $attachmentName,
            $attachmentDesc,
            $attachedPoint
        );
        $insertStagingStmt->execute();
        $received++;
    }

    $mysqli->commit();

} catch (Throwable $e) {
    $mysqli->rollback();
    $insertStagingStmt->close();
    $mysqli->close();
    respond_and_exit('Server exception: ' . $e->getMessage(), 500);
}

// Phase 2: drain staging into the normalized tables. Runs in autocommit so
// each statement inside the procedure holds its locks as briefly as possible.
// Parallel scanner nodes can deadlock each other here (1213) or time out
// (1205); that is harmless because the procedure is idempotent and the rows
// are already committed to staging, so the next ingest call picks them up.
$processed = 'no records';

if ($received > 0) {
    $processed = 'deferred';

    for ($attempt = 1; $attempt <= 3; $attempt++) {
        try {
            $mysqli->query('CALL sp_process_staging()');
            while ($mysqli->more_results() && $mysqli->next_result()) {
                // flush any extra result sets the CALL produces
            }
            $processed = 'yes';
            break;
        } catch (mysqli_sql_exception $e) {
            if (!in_array($e->getCode(), [1213, 1205], true) || $attempt === 3) {
                break;
            }
            usleep(100000 * $attempt);
        }
    }
}

$insertStagingStmt->close();
$mysqli->close();

respond_and_exit(
    "Data received successfully"
    . " | received={$received} invalid={$invalid} processed={$processed}"
);
