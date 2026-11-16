<?php
// Called by the website (navigator.sendBeacon): ?v=1&p=<page> for a view, ?e=<event> for an event.
// Answers 204 with nothing; never sets a cookie.

declare(strict_types=1);
require __DIR__ . '/lib.php';

header('Cache-Control: no-store');
try {
    $event = (string)($_GET['e'] ?? '');
    if ($event !== '') {
        stats_event($event);
    } else {
        stats_view((string)($_GET['p'] ?? '/'), (string)($_GET['r'] ?? ''));
    }
} catch (Throwable $e) {
    // counting must never disturb the website
}
http_response_code(204);
