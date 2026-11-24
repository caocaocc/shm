use v5.14;
use warnings;
use DBI;
use File::Temp qw(tempdir);
use Test::More;
use Core::Routing::Store ();

plan skip_all => 'set ROUTING_MIGRATION_TEST for the isolated routing_migration_qa database'
    unless $ENV{ROUTING_MIGRATION_TEST};
my $db = DBI->connect('dbi:mysql:database=routing_migration_qa;host=' . ($ENV{DB_HOST} || '127.0.0.1'),
    $ENV{DB_USER}, $ENV{DB_PASS}, { RaiseError => 1, PrintError => 0 });
$db->do('CREATE TEMPORARY TABLE storage (user_id INT, name VARCHAR(32))');

for my $name ('routing:7', 'routingp:abcdef') {
    local $Core::Routing::Store::DIRECTORY = tempdir(CLEANUP => 1);
    $db->do('INSERT INTO storage VALUES (0,?)', undef, $name);
    eval { Core::Routing::Store::key($db, 1) };
    is($@, "KEY_UNAVAILABLE\n", "$name requires the original shared key");
    ok(!-e "$Core::Routing::Store::DIRECTORY/key", 'a replacement key was not created');
    $db->do('DELETE FROM storage');
}

local $Core::Routing::Store::DIRECTORY = tempdir(CLEANUP => 1);
my $first = Core::Routing::Store::key($db, 1);
is(length($first), 32, 'a new site receives an AES-256 key');
is(Core::Routing::Store::key($db, 0), $first, 'the second reader receives the same key');
my $path = "$Core::Routing::Store::DIRECTORY/key";
chmod 0400, $path or die $!;
is(Core::Routing::Store::key($db, 0), $first, 'an owner-read-only backed up key works');
chmod 0700, $path or die $!;
eval { Core::Routing::Store::key($db, 0) };
is($@, "KEY_UNAVAILABLE\n", 'runtime and installation reject an executable key');
done_testing;
