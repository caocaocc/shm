use v5.14;
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Core::ServiceOptions;

my $fallback = 'SERVICE_OPTIONS_SYNC_FAILED';
is_deeply(Core::ServiceOptions::_task_diagnostics({12 => 'REMOTE_HTTP'}, $fallback),
    {error => 'REMOTE_HTTP'}, 'a single sanitized provider failure remains actionable');
is_deeply(Core::ServiceOptions::_task_diagnostics({12 => 'REMOTE_HTTP', 13 => 'REMOTE_HTTP'}, $fallback),
    {error => 'REMOTE_HTTP'}, 'an agreeing batch reports its actual common failure');
is_deeply(Core::ServiceOptions::_task_diagnostics({12 => 'REMOTE_HTTP', 13 => 'STATE_UNSAFE'}, $fallback),
    {error => $fallback, errors => {12 => 'REMOTE_HTTP', 13 => 'STATE_UNSAFE'}},
    'differing item failures retain a generic summary and numeric per-service codes');
is_deeply(Core::ServiceOptions::_task_diagnostics({}, $fallback), {error => $fallback},
    'an unstructured exception has no provider code to substitute');

my %many = map {$_ => $_ % 2 ? 'REMOTE_HTTP' : 'STATE_UNSAFE'} 1..150;
$many{'do-not-expose-secret-key'} = 'REMOTE_HTTP';
$many{4} = {secret => 'do-not-expose-secret-value'};
$many{5} = 'private exception do-not-expose-secret-value';
my $bounded = Core::ServiceOptions::_task_diagnostics(\%many, $fallback);
is(scalar keys %{$bounded->{errors}}, 100, 'diagnostic map has a fixed maximum of 100 items');
is_deeply([sort {$a <=> $b} keys %{$bounded->{errors}}], [1..100],
    'only bounded numeric service identities can appear');
is($bounded->{errors}{4}, 'SERVICE_OPTIONS_ERROR', 'structured untrusted errors reduce to a fixed code');
is($bounded->{errors}{5}, 'SERVICE_OPTIONS_ERROR', 'raw exception text reduces to a fixed code');
unlike(JSON::PP->new->encode($bounded), qr/do-not-expose|private exception|secret/,
    'diagnostic results cannot contain arbitrary keys, objects or error text');
my $validation = Core::ServiceOptions::_task_diagnostics({12 => 'INVALID_RULES'}, $fallback, 1);
is_deeply($validation->{errors}, {12 => 'INVALID_RULES'},
    'successful per-item validation results may expose safe diagnostic codes without changing task status');

done_testing();
