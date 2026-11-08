package Core::Pay::Local;

use v5.14;
use strict;
use warnings;
use utf8;
use parent 'Core::System::Service';
use File::Path qw(make_path);
use File::Spec;
use Fcntl qw(:DEFAULT :flock :mode);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use IO::Handle;
use Core::Utils qw(random_bytes exec_local_file);

sub root { $ENV{SHM_ROOT_DIR} || '/app' }
sub source_directory { File::Spec->catdir(root(), 'pay_systems') }
sub target_directory { File::Spec->catdir(root(), 'data', 'pay_systems') }
sub is_local {
    my ($self, $name) = @_;
    return 0 unless defined($name) && !ref($name) && $name =~ /\A[A-Za-z0-9_-]+\z/;
    my $path = File::Spec->catfile(source_directory(), "$name.cgi");
    return -f $path && !-l $path ? 1 : 0;
}
sub profile {
    my ($self, $name, $profile) = @_;
    return $profile unless ref($profile) eq 'HASH';
    my $module = $profile->{paysystem} || $name;
    return $profile unless $self->is_local($module);
    my $path = File::Spec->catfile(source_directory(), "$module.json");
    return $profile unless -e $path || -l $path;
    my $defaults = eval { JSON::PP->new->utf8->decode(_read($path)) };
    die "本地支付模块默认配置无效\n" unless ref($defaults) eq 'HASH'
        && !grep { !/\A(?:name|show_for_client|payment_url|action)\z/ } keys %$defaults;
    return { %$defaults, %$profile };
}
sub _uid { my @pw = getpwnam('www-data'); @pw ? $pw[2] : 33 }
sub _read {
    my ($path) = @_;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die "无法读取本地支付模块\n";
    my @st = stat($fh);
    die "本地支付模块文件不安全\n" unless S_ISREG($st[2]) && $st[3] == 1;
    binmode $fh;
    my $data = do { local $/; <$fh> };
    close($fh) or die "无法关闭本地支付模块文件\n";
    return $data;
}
sub _publish {
    my ($path, $bytes, $mode) = @_;
    my $temp = "$path." . unpack('H*', random_bytes(12));
    sysopen(my $fh, $temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        or die "无法创建本地支付模块文件\n";
    binmode $fh;
    my $ok = eval {
        print {$fh} $bytes or die "无法写入本地支付模块文件\n";
        chmod($mode, $fh) == 1 or die "无法设置本地支付模块权限\n";
        chown(_uid(), -1, $fh) == 1 or die "无法设置本地支付模块所有者\n" if $> == 0;
        $fh->sync or die "无法同步本地支付模块文件\n";
        close($fh) or die "无法关闭本地支付模块文件\n";
        rename($temp, $path) or die "无法发布本地支付模块文件\n";
        1;
    };
    unless ($ok) { my $error = $@; close $fh; unlink $temp; die $error; }
}
sub install {
    my ($self) = @_;
    my $source = source_directory();
    return 1 unless -d $source;
    die "本地支付模块源目录不安全\n" if -l $source;
    my $target = target_directory();
    make_path($target, {mode => 0755}) unless -e $target || -l $target;
    my @st = lstat($target);
    die "本地支付模块目录不安全\n" unless @st && S_ISDIR($st[2]) && !S_ISLNK($st[2])
        && ($st[4] == _uid() || ($> == 0 && $st[4] == 0)) && !($st[2] & 0022);
    chown(_uid(), -1, $target) == 1 or die "无法设置支付模块目录所有者\n" if $> == 0;
    my $lock_path = "$target/.local.lock";
    sysopen(my $lock, $lock_path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
        or die "无法锁定本地支付模块\n";
    my @lock_st = stat($lock);
    die "本地支付模块锁文件不安全\n" unless S_ISREG($lock_st[2]) && $lock_st[3] == 1
        && ($lock_st[2] & 0777) == 0600 && ($lock_st[4] == _uid() || ($> == 0 && $lock_st[4] == 0));
    chown(_uid(), -1, $lock) == 1 or die "无法设置本地支付模块锁所有者\n" if $> == 0;
    flock($lock, LOCK_EX) or die "无法锁定本地支付模块\n";
    my $manifest_path = "$target/.local.json";
    my $manifest = (-e $manifest_path || -l $manifest_path)
        ? eval { JSON::PP->new->decode(_read($manifest_path)) } : {};
    die "本地支付模块安装记录无效\n" unless ref($manifest) eq 'HASH';
    opendir(my $dh, $source) or die "无法读取本地支付模块目录\n";
    my @modules = sort grep { /\A[A-Za-z0-9_-]+\.cgi\z/ } readdir($dh);
    closedir($dh);
    for my $file (@modules) {
        my $bytes = _read("$source/$file");
        my $digest = sha256_hex($bytes);
        my $path = "$target/$file";
        if (-e $path || -l $path) {
            my $old = sha256_hex(_read($path));
            die "本地支付模块与现有文件冲突，请保留原文件后核对\n"
                unless $old eq $digest || ($manifest->{$file} // '') eq $old;
        }
        _publish($path, $bytes, 0755);
        $manifest->{$file} = $digest;
        _publish($manifest_path, JSON::PP->new->canonical->encode($manifest), 0600);
        # Only trusted bundled modules are initialized. HTTP parameters never
        # select executable files, and CGI request environment is not inherited.
        {
            local %ENV = %ENV;
            delete @ENV{grep { /\A(?:HTTP_|REQUEST_|CONTENT_|QUERY_STRING\z|SCRIPT_|PATH_INFO\z)/ } keys %ENV};
            my $result = exec_local_file(cmd => [$^X, $path, '--install'], timeout => 60);
            die "本地支付模块初始化失败，请检查服务日志和已有订单凭据\n" unless $result->{success};
        }
    }
    _publish($manifest_path, JSON::PP->new->canonical->encode($manifest), 0600);
    sysopen(my $dir, $target, O_RDONLY | O_NOFOLLOW) or die "无法同步支付模块目录\n";
    $dir->sync or die "无法同步支付模块目录\n";
    close $dir;
    return 1;
}

1;
