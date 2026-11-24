use v5.14;
use warnings;
use Test::More;
use Time::HiRes ();
use Core::Routing::Publish ();

my $now = Time::HiRes::time();
my $ran = 0;
eval { Core::Routing::Publish::within_deadline($now - 1, sub { $ran++ }) };
is($@, "REMOTE_HTTP\n", 'an exhausted batch refuses the next remote operation');
is($ran, 0, 'the remote operation did not start');

my $answer = Core::Routing::Publish::within_deadline($now + 5, sub { 42 });
is($answer, 42, 'a successful operation returns its response');
eval { Core::Routing::Publish::within_deadline($now + 5, sub { die "source failure\n" }) };
is($@, "source failure\n", 'the underlying error is retained');

{
    local $SIG{ALRM} = sub { die "enclosing worker deadline expired\n" };
    Time::HiRes::alarm(10);
    my $completed;
    eval {
        Core::Routing::Publish::within_deadline(Time::HiRes::time() + 0.10, sub {
            Time::HiRes::sleep(3);
            $completed = 1;
        });
    };
    my $error = $@;
    my $remaining = Time::HiRes::alarm(0);
    is($error, "REMOTE_HTTP\n", 'a slow operation reports the public timeout code');
    ok(!$completed, 'the operation was interrupted');
    cmp_ok($remaining, '>', 0, 'the enclosing worker alarm is restored');
    cmp_ok($remaining, '<', 10, 'the worker alarm includes the time already spent');
}
done_testing;
