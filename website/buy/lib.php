<?php
// Shared code of the shop: configuration, Stripe API, webhook signature, licence files, e-mail (also trials).
// No libraries – plain PHP 8 with curl and sodium (standard on the hosting).

declare(strict_types=1);

// Errors go to the server log, never into a page, a licence download or a webhook answer.
ini_set('display_errors', '0');
ini_set('log_errors', '1');

const STRIPE_VERSION = '2024-06-20';

$configFile = getenv('DCR_SHOP_CONFIG') ?: __DIR__ . '/config.php';   // another file only for local tests
if (!is_file($configFile)) {
    http_response_code(503);
    exit('The shop is not set up yet (buy/config.php is missing).');
}
require $configFile;

// Visit statistics (stats/), when they are on the server: checkouts and purchases are counted there.
if (is_file(dirname(__DIR__) . '/stats/lib.php')) { require_once dirname(__DIR__) . '/stats/lib.php'; }
function count_event(string $name): void {
    if (function_exists('stats_event')) { try { stats_event($name); } catch (Throwable $e) {} }
}

/** Folder for issued licences and the record of handled payments – not reachable from the web (.htaccess). */
function data_dir(string $sub = ''): string {
    $base = defined('DATA_DIR') ? DATA_DIR : __DIR__ . '/data';
    $dir = $base . ($sub === '' ? '' : '/' . $sub);
    if (!is_dir($dir)) { mkdir($dir, 0700, true); }
    return $dir;
}

function log_line(string $text): void {
    file_put_contents(data_dir() . '/shop.log', gmdate('Y-m-d H:i:s') . "  $text\n", FILE_APPEND | LOCK_EX);
}

// MARK: - Stripe API

/** Calls the Stripe API (form-encoded) and returns the decoded answer; throws on an error answer. */
function stripe(string $method, string $path, array $params = []): array {
    $url = rtrim(defined('STRIPE_API') ? STRIPE_API : 'https://api.stripe.com', '/') . $path;
    $body = http_build_query($params, '', '&');
    if ($method === 'GET' && $body !== '') { $url .= '?' . $body; }
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_USERPWD => STRIPE_SECRET_KEY . ':',
        CURLOPT_HTTPHEADER => ['Stripe-Version: ' . STRIPE_VERSION],
        CURLOPT_TIMEOUT => 30,
    ]);
    if ($method !== 'GET') { curl_setopt($ch, CURLOPT_POSTFIELDS, $body); }
    $answer = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $error = curl_error($ch);
    if ($answer === false) { throw new RuntimeException("Stripe not reachable: $error"); }
    $data = json_decode((string)$answer, true);
    if ($status >= 400 || !is_array($data)) {
        $message = is_array($data) ? ($data['error']['message'] ?? 'unknown error') : 'unreadable answer';
        throw new RuntimeException("Stripe $status: $message");
    }
    return $data;
}

/** Checks the Stripe-Signature header of a webhook (HMAC-SHA256, 5 minutes tolerance). */
function webhook_signature_ok(string $payload, string $header, string $secret): bool {
    $timestamp = null;
    $signatures = [];
    foreach (explode(',', $header) as $part) {
        [$key, $value] = array_pad(explode('=', trim($part), 2), 2, '');
        if ($key === 't') { $timestamp = (int)$value; }
        if ($key === 'v1') { $signatures[] = $value; }
    }
    if ($timestamp === null || !$signatures || abs(time() - $timestamp) > 300) { return false; }
    $expected = hash_hmac('sha256', $timestamp . '.' . $payload, $secret);
    foreach ($signatures as $signature) {
        if (hash_equals($expected, $signature)) { return true; }
    }
    return false;
}

// MARK: - Licence

/** Mac ID as the app shows it, without dashes: 16 characters of 0-9 A-Z without I L O U; null when not valid. */
function normalized_mac(string $id): ?string {
    $mac = strtoupper(str_replace(['-', ' '], '', trim($id)));
    return preg_match('/^[0-9A-HJKMNP-TV-Z]{16}$/', $mac) ? $mac : null;
}

function formatted_mac(string $mac): string {
    return implode('-', str_split($mac, 4));
}

function base64url(string $data): string {
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

/** "DCR1.<payload>.<signature>" – the same format as tools/make_license.swift (Ed25519 over the JSON bytes). */
function make_licence(string $name, string $mac, int $expires): string {
    $seed = base64_decode(LICENSE_PRIVATE_KEY, true);
    if ($seed === false || strlen($seed) !== SODIUM_CRYPTO_SIGN_SEEDBYTES) {
        throw new RuntimeException('LICENSE_PRIVATE_KEY is not a valid key');
    }
    $secret = sodium_crypto_sign_secretkey(sodium_crypto_sign_seed_keypair($seed));
    $payload = [   // keys in alphabetical order, like the Swift tool
        'expires' => gmdate('Y-m-d\TH:i:s\Z', $expires),
        'issued' => gmdate('Y-m-d\TH:i:s\Z'),
        'machine' => $mac,
        'name' => $name,
        'v' => 1,
    ];
    $json = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $signature = sodium_crypto_sign_detached($json, $secret);
    return 'DCR1.' . base64url($json) . '.' . base64url($signature) . "\n";
}

function licence_file_name(string $name): string {
    $safe = rtrim(trim(preg_replace('/[\/\\\\:*?"<>|]+/', '-', $name)), '.');
    return 'DualCamRecorder License – ' . ($safe === '' ? 'Customer' : $safe) . '.dcrlicense';
}

/** Latest licence of a subscription (written by the webhook), or null. */
function latest_licence(string $subscription): ?array {
    $file = data_dir('subscriptions') . '/' . preg_replace('/[^A-Za-z0-9_]/', '', $subscription) . '.json';
    if (!is_file($file)) { return null; }
    $data = json_decode((string)file_get_contents($file), true);
    return is_array($data) ? $data : null;
}

// MARK: - E-mail

/** Sends the licence of a subscription as an attachment (and a copy to the shop owner). */
function mail_licence(string $to, string $name, string $licence, int $expires, string $plan): bool {
    $until = gmdate('j F Y', $expires);
    $site = SITE_URL;
    $download = download_url();
    $manage = defined('CUSTOMER_PORTAL_URL') && CUSTOMER_PORTAL_URL !== '' ? "\nManage or cancel your subscription: " . CUSTOMER_PORTAL_URL . "\n" : '';
    $text = <<<TXT
Hello $name,

thank you for your DualCamRecorder subscription ($plan).

Your licence is attached. It is made for one Mac and is valid until $until.
1. Install DualCamRecorder: $download
2. Open DualCamRecorder → License… and drop the attached file on the window, or press Import License….

Every time the subscription renews you get a new licence file by e-mail – import it the same way.
$manage
Benjoni s.r.o.
$site
TXT;
    return mail_with_licence($to, 'Your DualCamRecorder licence', $text, licence_file_name($name), $licence);
}

/** Sends a trial licence (14 days, one Mac). */
function mail_trial_licence(string $to, string $name, string $licence, int $expires): bool {
    $until = gmdate('j F Y', $expires);
    $site = SITE_URL;
    $download = download_url();
    $text = <<<TXT
Hello $name,

here is your free DualCamRecorder trial licence. It is made for one Mac and is valid until $until.
1. Install DualCamRecorder: $download
2. Open DualCamRecorder → License… and drop the attached file on the window, or press Import License….

Recording is on for the trial. After it the app still opens, plays, edits and exports – only recording stops.
To keep recording, buy a licence: $site/#buy

Questions or feedback – just reply to this e-mail.

Benjoni s.r.o.
$site
TXT;
    return mail_with_licence($to, 'Your DualCamRecorder trial licence', $text, licence_file_name($name), $licence,
                             defined('SUPPORT_EMAIL') ? SUPPORT_EMAIL : '');
}

/** E-mail with one licence file attached (and a copy to the shop owner, when set). */
function mail_with_licence(string $to, string $subject, string $text, string $file, string $licence, string $replyTo = ''): bool {
    $boundary = 'dcr-' . bin2hex(random_bytes(8));
    $body = "--$boundary\r\n"
        . "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        . str_replace("\n", "\r\n", $text) . "\r\n"
        . "--$boundary\r\n"
        . "Content-Type: application/octet-stream; name=\"=?UTF-8?B?" . base64_encode($file) . "?=\"\r\n"
        . "Content-Transfer-Encoding: base64\r\n"
        . "Content-Disposition: attachment; filename=\"=?UTF-8?B?" . base64_encode($file) . "?=\"\r\n\r\n"
        . chunk_split(base64_encode($licence)) . "--$boundary--\r\n";
    $headers = "From: " . MAIL_FROM . "\r\n"
        . ($replyTo !== '' ? "Reply-To: $replyTo\r\n" : '')
        . (defined('MAIL_COPY_TO') && MAIL_COPY_TO !== '' ? "Bcc: " . MAIL_COPY_TO . "\r\n" : '')
        . "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"$boundary\"\r\n";
    $subject = '=?UTF-8?B?' . base64_encode($subject) . '?=';
    if (defined('MAIL_TEST_FILE')) {   // local tests: write the e-mail into a file instead of sending it
        file_put_contents(MAIL_TEST_FILE, "To: $to\r\nSubject: $subject\r\n$headers\r\n$body");
        return true;
    }
    return mail($to, $subject, $body, $headers);
}

/** The newest app zip (from version.json, written by tools/release.sh). */
function download_url(): string {
    $info = json_decode((string)@file_get_contents(dirname(__DIR__) . '/version.json'), true);
    return is_array($info) && isset($info['url']) ? (string)$info['url'] : SITE_URL;
}

function h(string $text): string {
    return htmlspecialchars($text, ENT_QUOTES, 'UTF-8');
}
