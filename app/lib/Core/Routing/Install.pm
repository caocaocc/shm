package Core::Routing::Install;
use v5.14;
use warnings;
use Fcntl qw(:mode);

sub prepare_volume {
    my ($base) = @_;
    my $dir = "$base/data/routing-templates";
    my @worker = getpwnam('www-data');
    die "Missing www-data account\n" unless @worker;
    unless (-e $dir || -l $dir) {
        mkdir($dir, 0700) && chown($worker[2], $worker[3], $dir) == 1 or die "Cannot prepare routing data: $!\n";
    }
    my @info = lstat($dir);
    die "Invalid routing directory permissions\n" unless @info && S_ISDIR($info[2]) &&
        ($info[2] & 0777) == 0700 && $info[4] == $worker[2];
    my @key = lstat("$dir/key");
    die "Invalid routing key or permissions\n" if @key &&
       (!S_ISREG($key[2]) || $key[7] != 32 || $key[4] != $worker[2] || (($key[2] & 0777) != 0600 && ($key[2] & 0777) != 0400));
}

sub install {
    my ($db) = @_;
    $db->do(q{INSERT INTO config (`key`,value) VALUES ('routing',JSON_OBJECT('batch_window_seconds',3,'min_publish_interval_seconds',3600))
        ON DUPLICATE KEY UPDATE value=JSON_INSERT(value,'$.batch_window_seconds',3,'$.min_publish_interval_seconds',3600)})
        or die "Cannot initialize routing configuration\n";
}
1;
