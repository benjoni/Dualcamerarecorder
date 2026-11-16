<?php
// Visit counter without cookies and without third parties. One small JSON file per day in data/ (not served):
// page views, unique visitors, where they came from, and events (Buy clicks, checkouts, purchases …).
// Unique visitors: a hash of IP + browser with a salt that changes every day and is deleted after it –
// the IP itself is never stored and visitors cannot be followed from one day to the next.

declare(strict_types=1);

ini_set('display_errors', '0');

const STATS_EVENTS = [
    'buy' => 'Buy / Pricing clicks',
    'plan_monthly' => 'Monthly chosen',
    'plan_yearly' => 'Yearly chosen',
    'checkout' => 'Payment page opened',
    'purchase' => 'Paid (licence sent)',
    'video' => 'Video played with sound',
    'download' => 'App downloads (success page)',
];

function stats_dir(): string {
    $dir = __DIR__ . '/data';
    if (!is_dir($dir)) { mkdir($dir, 0700, true); }
    return $dir;
}

function stats_is_bot(string $agent): bool {
    return $agent === '' || preg_match('/bot|crawl|spider|slurp|curl|wget|python|preview|facebookexternalhit|headless|monitor/i', $agent) === 1;
}

/** Salt of today (made on the first visit of the day; older ones are deleted). */
function stats_salt(string $day): string {
    $file = stats_dir() . "/salt-$day";
    if (!is_file($file)) {
        file_put_contents($file, bin2hex(random_bytes(16)), LOCK_EX);
        foreach (glob(stats_dir() . '/salt-*') ?: [] as $old) {
            if ($old !== $file) { @unlink($old); }
        }
    }
    return trim((string)file_get_contents($file));
}

/** Changes the file of today under a lock. */
function stats_update(callable $change): void {
    $day = gmdate('Y-m-d');
    $fh = fopen(stats_dir() . "/$day.json", 'c+');
    if ($fh === false) { return; }
    flock($fh, LOCK_EX);
    $data = json_decode((string)stream_get_contents($fh), true);
    if (!is_array($data)) { $data = ['views' => 0, 'visitors' => [], 'refs' => [], 'pages' => [], 'events' => []]; }
    $data = $change($data, $day);
    ftruncate($fh, 0);
    rewind($fh);
    fwrite($fh, json_encode($data));
    fflush($fh);
    flock($fh, LOCK_UN);
    fclose($fh);
}

/** A page view (from the browser). */
function stats_view(string $page, string $referrer): void {
    $agent = (string)($_SERVER['HTTP_USER_AGENT'] ?? '');
    if (stats_is_bot($agent)) { return; }
    $ip = (string)($_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? '');
    $ip = trim(explode(',', $ip)[0]);
    stats_update(function (array $d, string $day) use ($page, $referrer, $agent, $ip) {
        $d['views']++;
        $visitor = substr(hash('sha256', stats_salt($day) . "|$ip|$agent"), 0, 16);
        $d['visitors'][$visitor] = 1;
        $host = strtolower((string)parse_url($referrer, PHP_URL_HOST));
        $host = preg_replace('/^www\./', '', $host);
        $ref = ($host === '' || str_ends_with($host, 'benjoni.com')) ? '(direct)' : $host;
        $d['refs'][$ref] = ($d['refs'][$ref] ?? 0) + 1;
        $page = substr(preg_replace('/[^A-Za-z0-9\/._#-]/', '', $page), 0, 60) ?: '/';
        $d['pages'][$page] = ($d['pages'][$page] ?? 0) + 1;
        return $d;
    });
}

/** An event (Buy click, checkout, purchase …); unknown names are ignored. */
function stats_event(string $name): void {
    if (!isset(STATS_EVENTS[$name])) { return; }
    if ($name !== 'purchase' && stats_is_bot((string)($_SERVER['HTTP_USER_AGENT'] ?? 'server'))) { return; }
    stats_update(function (array $d) use ($name) {
        $d['events'][$name] = ($d['events'][$name] ?? 0) + 1;
        return $d;
    });
}

/** Days of the last $days days, newest first: [day => data]. */
function stats_days(int $days): array {
    $out = [];
    for ($i = 0; $i < $days; $i++) {
        $day = gmdate('Y-m-d', time() - $i * 86400);
        $data = json_decode((string)@file_get_contents(stats_dir() . "/$day.json"), true);
        $out[$day] = is_array($data) ? $data : ['views' => 0, 'visitors' => [], 'refs' => [], 'pages' => [], 'events' => []];
    }
    return $out;
}
