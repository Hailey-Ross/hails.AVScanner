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

function build_data_hash(string $avatarName, string $attachmentName, string $attachmentDesc, int $attachedPoint): string
{
    $hashSource = json_encode(
        [
            'avatar_name' => $avatarName,
            'attachment_name' => $attachmentName,
            'attachment_desc' => $attachmentDesc,
            'attached_point' => $attachedPoint
        ],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
    );

    if ($hashSource === false) {
        $hashSource = $avatarName . '|' . $attachmentName . '|' . $attachmentDesc . '|' . $attachedPoint;
    }

    return hash('sha256', $hashSource);
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

$selectStmt = $mysqli->prepare("
    SELECT id, avatar_name, attachment_name, attachment_desc, attached_point, data_hash, first_seen_utc, changed_utc
    FROM attachments_current
    WHERE avatar_uuid = ? AND attachment_uuid = ?
    LIMIT 1
");

$insertCurrentStmt = $mysqli->prepare("
    INSERT INTO attachments_current (
        avatar_uuid, avatar_name, attachment_uuid, attachment_name,
        attachment_desc, attached_point, data_hash,
        first_seen_utc, changed_utc
    ) VALUES (?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())
");

$insertStaleStmt = $mysqli->prepare("
    INSERT INTO stale_attachments (
        current_row_id, avatar_uuid, avatar_name,
        attachment_uuid, attachment_name, attachment_desc,
        attached_point, data_hash,
        first_seen_utc, changed_utc, stale_moved_utc
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP())
");

$updateCurrentStmt = $mysqli->prepare("
    UPDATE attachments_current
    SET avatar_name = ?, attachment_name = ?, attachment_desc = ?, attached_point = ?, data_hash = ?, changed_utc = UTC_TIMESTAMP()
    WHERE id = ?
");

if (!$selectStmt || !$insertCurrentStmt || !$insertStaleStmt || !$updateCurrentStmt) {
    respond_and_exit('Statement preparation failed: ' . $mysqli->error, 500);
}

$inserted = 0;
$updated = 0;
$ignored = 0;
$invalid = 0;

try {
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
        $attachedPoint = (int)($record['attached_point'] ?? 0);

        if ($avatarUuid === '' || $avatarName === '' || $attachmentUuid === '' || $attachmentName === '') {
            $invalid++;
            continue;
        }

        $dataHash = build_data_hash($avatarName, $attachmentName, $attachmentDesc, $attachedPoint);

        $selectStmt->bind_param('ss', $avatarUuid, $attachmentUuid);
        $selectStmt->execute();
        $result = $selectStmt->get_result();
        $existing = $result ? $result->fetch_assoc() : null;
      
        if (!$existing) {
            $insertCurrentStmt->bind_param(
                'sssssis',
                $avatarUuid,
                $avatarName,
                $attachmentUuid,
                $attachmentName,
                $attachmentDesc,
                $attachedPoint,
                $dataHash
            );
            $insertCurrentStmt->execute();
            $inserted++;
            continue;
        }

        if (hash_equals((string)$existing['data_hash'], $dataHash)) {
            $ignored++;
            continue;
        }

        $insertStaleStmt->bind_param(
            'isssssisss',
            $existing['id'],
            $avatarUuid,
            $existing['avatar_name'],
            $attachmentUuid,
            $existing['attachment_name'],
            $existing['attachment_desc'],
            $existing['attached_point'],
            $existing['data_hash'],
            $existing['first_seen_utc'],
            $existing['changed_utc']
        );
        $insertStaleStmt->execute();

        $updateCurrentStmt->bind_param(
            'sssisi',
            $avatarName,
            $attachmentName,
            $attachmentDesc,
            $attachedPoint,
            $dataHash,
            $existing['id']
        );
        $updateCurrentStmt->execute();

        $updated++;
    }

    $mysqli->commit();

    respond_and_exit(
        "Data received successfully"
        . " | inserted={$inserted} updated={$updated} ignored={$ignored} invalid={$invalid}"
    );

} catch (Throwable $e) {
    $mysqli->rollback();
    respond_and_exit('Server exception: ' . $e->getMessage(), 500);
} finally {
    $selectStmt->close();
    $insertCurrentStmt->close();
    $insertStaleStmt->close();
    $updateCurrentStmt->close();
    $mysqli->close();
}
