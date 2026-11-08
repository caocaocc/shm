use v5.14;
use strict;
use warnings;
use utf8;
use Test::More;
use Core::Sql::Data;
use Core::Utils ();

{
    package ProtectedSqlLogger;
    sub debug {my $self = shift; push @{$self->{messages}}, join('', @_)}
    sub error {my $self = shift; push @{$self->{messages}}, join('', @_)}
    package ProtectedSqlObject;
    our @ISA = ('Core::Sql::Data');
    sub table { $_[0]{table} }
    sub dbh { $_[0]{db} }
    package ProtectedSqlDBH;
    sub do {
        my ($self, $query, $attributes, @binds) = @_;
        $self->{last_write} = {query => $query, binds => \@binds,
            PrintError => $self->{PrintError}, ShowErrorStatement => $self->{ShowErrorStatement}};
        die 'synthetic-private-sql-marker' if ($self->{write_mode} // '') eq 'throw';
        return undef if ($self->{write_mode} // '') eq 'false';
        return '0E0' if ($self->{write_mode} // '') eq 'zero';
        return 1;
    }
    sub prepare_cached {
        my ($self, $query) = @_;
        $self->{last_read} = {query => $query};
        return undef if $self->{prepare_fails};
        return bless {db => $self}, 'ProtectedSqlStatement';
    }
    sub selectall_hashref {
        my ($self, $query, $key, $attributes, @binds) = @_;
        die 'synthetic-private-sql-marker' if $self->{named_read_fails};
        return {a => {id => 'a'}};
    }
    sub errstr {'synthetic-private-sql-marker'}
    sub err { $_[0]{query_fails} ? 1 : undef }
    sub selectall_arrayref {
        my ($self, $query, $attributes, @binds) = @_;
        $self->{reference_metadata} = {query => $query, binds => \@binds};
        die 'synthetic-private-sql-marker' if $self->{metadata_fails};
        return $self->{references} || [];
    }
    sub quote_identifier {
        my ($self, $identifier) = @_;
        $identifier =~ s/`/``/g;
        return '`' . $identifier . '`';
    }
    sub selectrow_array {
        my ($self, $query, $attributes, @binds) = @_;
        push @{$self->{reference_checks}}, {query => $query, binds => \@binds};
        return undef if $self->{query_fails};
        return $self->{referenced_queries}{$query} ? 1 : undef;
    }
    package ProtectedSqlStatement;
    sub bind_param {$_[0]{db}{last_read}{binds}[$_[1] - 1] = $_[2]; 1}
    sub execute {return !$_[0]{db}{execute_fails}}
    sub fetchrow_hashref {
        my $self = shift;
        return undef if $self->{read}++;
        return {value => 'synthetic-private-sql-marker'};
    }
    sub finish {1}
}

my $logger = bless {messages => []}, 'ProtectedSqlLogger';
my $dbh = bless {PrintError => 1, ShowErrorStatement => 1, RaiseError => 0}, 'ProtectedSqlDBH';
my $object = bless {db => $dbh, table => 'config'}, 'ProtectedSqlObject';
my $private = 'synthetic-private-sql-marker';
{
    no warnings 'redefine';
    local *Core::Sql::Data::logger = sub {$logger};
    is($object->do('UPDATE config SET value=?', $private), 1, 'configuration write executes normally');
    is_deeply($dbh->{last_write}{binds}, [$private], 'the real database receives the original bind, not a masked value');
    is($dbh->{last_write}{PrintError}, 0, 'sensitive database diagnostics are disabled during the call');
    is($dbh->{PrintError}, 1, 'the original database diagnostic setting is restored afterwards');
    unlike(join(' ', @{$logger->{messages}}), qr/\Q$private\E/, 'configuration bind values never enter SQL debug logs');
    $dbh->{write_mode} = 'false'; $logger->{messages} = [];
    ok(!defined $object->do('UPDATE config SET value=?', $private), 'a failed write remains failed');
    unlike(join(' ', @{$logger->{messages}}), qr/\Q$private\E/, 'failed SQL writes do not log binds or database excerpts');
    $dbh->{write_mode} = 'throw';
    ok(!eval {$object->do('UPDATE config SET value=?', $private); 1}, 'a thrown database error still stops the caller');
    unlike($@, qr/\Q$private\E/, 'thrown errors use a fixed safe diagnostic');
    $dbh->{write_mode} = 'zero';
    is($object->do('UPDATE config SET value=?', $private), 0, 'zero affected rows keep the original return semantics');
    delete $dbh->{write_mode}; $logger->{messages} = [];
    is_deeply(scalar $object->query('SELECT value FROM config WHERE `key`=?', $private), [{value => $private}], 'configuration results remain available in scalar context');
    my @rows = $object->query('SELECT value FROM config WHERE `key`=?', $private);
    is_deeply(\@rows, [{value => $private}], 'configuration results retain their list-context return semantics');
    is_deeply($dbh->{last_read}{binds}, [$private], 'read parameters are still bound unchanged');
    unlike(join(' ', @{$logger->{messages}}), qr/\Q$private\E/, 'configuration reads do not leak SQL arguments or values');
    $dbh->{prepare_fails} = 1;
    ok(!eval {$object->query('SELECT value FROM config', $private); 1}, 'a failed prepare stops the caller');
    unlike($@, qr/\Q$private\E/, 'prepare failure does not expose driver diagnostics');
    delete $dbh->{prepare_fails}; $dbh->{execute_fails} = 1;
    ok(!eval {$object->query('SELECT value FROM config', $private); 1}, 'a failed execute stops the caller');
    unlike($@, qr/\Q$private\E/, 'execute failure does not expose driver diagnostics');
    delete $dbh->{execute_fails}; $dbh->{named_read_fails} = 1;
    ok(!eval {$object->query_by_name('SELECT value FROM config', 'id', $private); 1}, 'a failed named read stops the caller');
    unlike($@, qr/\Q$private\E/, 'named read failure does not expose driver diagnostics');
    delete $dbh->{named_read_fails};
    $object->{table} = 'users'; $logger->{messages} = [];
    $object->log('SELECT 1 FROM users WHERE login=?', ['public-customer']);
    like(join(' ', @{$logger->{messages}}), qr/public-customer/, 'ordinary public SQL diagnostics retain their original behavior');
    $logger->{messages} = [];
    local $Core::Utils::sensitive_request = 1;
    $object->log('SELECT 1 FROM users WHERE login=?', [$private]);
    unlike(join(' ', @{$logger->{messages}}), qr/\Q$private\E/, 'an explicitly sensitive request protects other SQL tables as well');
}

subtest 'restrictive module audit references are checked before deletion' => sub {
    $object->{table} = 'users';
    $dbh->{references} = [];
    ok(!$object->has_external_references(table => 'users', column => 'user_id', value => 42), 'an unreferenced parent may be deleted');
    is_deeply($dbh->{reference_metadata}{binds}, ['users', 'user_id'], 'parent table and column names are metadata bind parameters');
    $dbh->{references} = [
        {child_table => 'owned_resources', child_column => 'user_id'},
        {child_table => 'module_audit', child_column => 'owner_id'},
        {child_table => 'module_audit', child_column => 'owner_id'},
    ];
    $dbh->{reference_checks} = [];
    $dbh->{referenced_queries} = {'SELECT 1 FROM `module_audit` WHERE `owner_id`=? LIMIT 1' => 1};
    ok($object->has_external_references(table => 'users', column => 'user_id', value => 42,
        ignore_tables => ['owned_resources']), 'an unknown module audit table protects its parent');
    is(scalar @{$dbh->{reference_checks}}, 1, 'owned resources are ignored and repeated metadata does not repeat a query');
    is_deeply($dbh->{reference_checks}[0]{binds}, [42], 'parent identity is a bind parameter');
    $dbh->{references} = [{child_table => 'module`audit', child_column => 'owner`id'}];
    $dbh->{reference_checks} = []; $dbh->{referenced_queries} = {};
    ok(!$object->has_external_references(table => 'users', column => 'user_id', value => 42), 'unusual metadata identifiers remain safe and usable');
    is($dbh->{reference_checks}[0]{query}, 'SELECT 1 FROM `module``audit` WHERE `owner``id`=? LIMIT 1', 'database metadata identifiers are quoted by the driver');
    is($dbh->{RaiseError}, 0, 'reference checks restore the caller database error mode');
    $dbh->{metadata_fails} = 1;
    ok(!eval {$object->has_external_references(table => 'users', column => 'user_id', value => 42); 1}, 'metadata failure stops deletion');
    unlike($@, qr/\Q$private\E/, 'metadata failure never returns database diagnostics');
    delete $dbh->{metadata_fails}; $dbh->{query_fails} = 1;
    ok(!eval {$object->has_external_references(table => 'users', column => 'user_id', value => 42); 1}, 'a child lookup failure stops deletion');
    unlike($@, qr/\Q$private\E/, 'child lookup failure never returns database diagnostics');
    delete $dbh->{query_fails};
    ok(!eval {$object->has_external_references(table => 'users', column => 'user_id', value => 42, ignore_tables => {}); 1}, 'invalid ignore lists are rejected');
};

done_testing();
