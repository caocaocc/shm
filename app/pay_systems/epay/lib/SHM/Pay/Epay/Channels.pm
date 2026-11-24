package SHM::Pay::Epay::Channels;
use v5.14;
use strict;
use warnings;
use utf8;
use JSON::PP;
use URI;
use SHM::Pay::Epay::Protocol qw(gateway_url rsa_key);
use SHM::Pay::Epay::Vault qw(unpack_json account_values save_account);
use Exporter 'import';
our @EXPORT_OK = qw(catalogue merchant settings change);
my @public = qw(name show_for_client type checkout);
my @private = qw(apiurl pid sign_type);
my @all = (@public, @private);
my @keys = qw(key merchant_private_key platform_public_key);

sub catalogue {
    my ($db, $lock) = @_;
    my $sql = q{SELECT value FROM config WHERE config.key='pay_systems'};
    my ($value) = $db->selectrow_array($sql . ($lock ? ' FOR UPDATE' : ''));
    my $public = unpack_json($value);
    my %accounts;
    for my $entry (@{$db->selectall_arrayref('SELECT profile, credential_box FROM epay_accounts'.($lock ? ' FOR UPDATE' : ''))}) {
        $accounts{$entry->[0]} = account_values($db, @$entry);
    }
    return ($public, \%accounts);
}
sub ours {
    my ($map, $id) = @_;
    my $row = $map->{$id};
    return ref($row) eq 'HASH' && ($row->{paysystem} // $id) eq 'epay';
}
sub selection {
    my ($row, $account) = @_;
    return $row->{fields} if ref($row->{fields}) eq 'ARRAY';
    return [@public, $account ? @private : ()];
}
sub signature {
    my ($own) = @_;
    return 'MD5' if exists $own->{key};
    return 'RSA' if exists $own->{merchant_private_key} || exists $own->{platform_public_key};
    return '';
}
sub origin {
    my ($address) = @_;
    return length($address // '') ? URI->new(gateway_url($address))->canonical->authority : '';
}
sub merchant {
    my ($accounts, $id) = @_;
    my $base = $accounts->{epay} || {};
    return {%$base} if $id eq 'epay';
    my $copy = $accounts->{$id} || {};
    my %result = (%$base, %$copy);
    if (my $mode = signature($copy)) {
        delete @result{$mode eq 'MD5' ? qw(merchant_private_key platform_public_key) : ('key')};
    } elsif (exists($copy->{apiurl}) && origin($copy->{apiurl}) ne origin($base->{apiurl})) {
        die "Changing provider requires separate credentials\n";
    }
    return \%result;
}
sub validate {
    my ($data) = @_;
    gateway_url($data->{apiurl});
    die "Invalid merchant ID\n" unless ($data->{pid} // '') =~ /\A[1-9][0-9]{0,11}\z/;
    if (exists $data->{key}) {
        die "Invalid MD5 credential\n" unless ($data->{key} // '') =~ /\A[^\x00-\x1f\x7f]{1,2048}\z/
            && !exists($data->{merchant_private_key}) && !exists($data->{platform_public_key});
    } else {
        rsa_key($data->{merchant_private_key}, 1);
        rsa_key($data->{platform_public_key}, 0);
    }
}
sub settings {
    my ($db) = @_;
    my ($entries, $accounts) = catalogue($db);
    my (%summary, %channels);
    for my $id (grep { ours($entries, $_) } keys %$entries) {
        my $row = $entries->{$id};
        my $account = merchant($accounts, $id);
        $summary{$id} = {apiurl => $account->{apiurl} // '', pid => $account->{pid} // '',
            sign_type => signature($account) || 'MD5', map { ("has_$_", length($account->{$_} // '') ? 1 : 0) } @keys} if keys %$account;
        $channels{$id} = {name => $row->{name} // $id, action => $row->{action} // 'submit',
            type => $row->{type} // '', show_for_client => $row->{show_for_client} && ($row->{enabled} // 1) ? 1 : 0};
        $channels{$id}{fields} = selection($row, $accounts->{$id}) if $id ne 'epay';
    }
    return {accounts => \%summary, channels => \%channels};
}
sub apply_public {
    my ($row, $main, $override, $account, $form) = @_;
    my %chosen = map { $_ => 1 } @$override;
    for my $field (@public) {
        my $stored = $field eq 'checkout' ? 'action' : $field;
        my $val = $chosen{$field} ? ($form && exists($form->{$field}) ? $form->{$field} : $row->{$stored}) : $main->{$stored};
        if ($field eq 'checkout') {
            die "Invalid checkout mode\n" unless defined($val) && $val =~ /\A(?:submit|api|create|mapi)\z/;
            $val = signature($account) eq 'RSA' ? 'create' : 'mapi' if $val ne 'submit';
        } elsif ($field eq 'type') {
            $val = $form->{custom_type} if $form && ($val // '') eq 'other' && $chosen{type};
            die "Invalid payment type\n" if length($val // '') && $val !~ /\A[a-z][a-z0-9_]{0,31}\z/;
        } elsif ($field eq 'name') {
            die "Invalid display name\n" unless ($val // '') =~ /\A[^\x00-\x1f\x7f]{1,128}\z/;
        } else {
            die "Invalid visibility\n" unless "$val" =~ /\A[01]\z/;
            $val = $val ? JSON::PP::true : JSON::PP::false;
        }
        if (defined($val) && length("$val")) { $row->{$stored} = $val }
        else { delete $row->{$stored} }
    }
    $row->{enabled} = JSON::PP::true if $row->{show_for_client} && exists($row->{enabled});
}
sub change {
    my ($db, $form) = @_;
    my ($entries, $accounts) = catalogue($db, 1);
    my $id = $form->{profile} // '';
    my $creating = !length($id);
    if ($creating) {
        my $last = 0;
        for (keys %$entries, keys %$accounts) { $last = $1 if /\Aepay_(\d+)\z/ && $1 > $last }
        $id = 'epay_'.($last + 1);
    } else {
        die "Unknown profile\n" unless $id =~ /\A[a-z][a-z0-9_-]{0,31}\z/ && ours($entries, $id);
    }
    my $deleting = ($form->{operation} // '') eq 'delete';
    if ($deleting) {
        die "Cannot delete primary channel\n" if $creating || $id eq 'epay';
        delete $entries->{$id};
        save_account($db, $id, {});
    } else {
        my $main = $entries->{epay} or die "Missing primary channel\n";
        my @fields = $id eq 'epay' ? @all : split /,/, ($form->{fields} // '');
        my %allowed = map { $_ => 1 } @all;
        my %selected;
        for (@fields) { die "Invalid override field\n" unless $allowed{$_} && !$selected{$_}++ }
        die "Missing copy name or visibility\n" unless $selected{name} && $selected{show_for_client};
        for my $field (qw(type checkout apiurl pid sign_type)) {
            die "Unselected field\n" if exists($form->{$field}) && !$selected{$field};
        }
        die "Unselected signing credentials\n" if !$selected{sign_type} && grep { exists $form->{$_} } @keys;
        my $before = merchant($accounts, $id);
        my $local = $accounts->{$id} || {};
        my %own;
        for my $field (qw(apiurl pid)) {
            next unless $selected{$field};
            my $value = exists($form->{$field}) ? $form->{$field} : $local->{$field};
            $own{$field} = $value if length($value // '');
        }
        if ($selected{sign_type}) {
            my $mode = $form->{sign_type} // signature($local);
            die "Invalid signature type\n" unless $mode =~ /\A(?:MD5|RSA)\z/;
            for my $key ($mode eq 'MD5' ? 'key' : qw(merchant_private_key platform_public_key)) {
                my $value = $form->{$key};
                $value = $local->{$key} unless length($value // '');
                $own{$key} = $value if length($value // '');
            }
            die "Missing signing credentials\n" if !signature(\%own) && ($id ne 'epay' || keys(%own));
        }
        $accounts->{$id} = \%own;
        my $effective = merchant($accounts, $id);
        if (signature(\%own) && origin($before->{apiurl}) && origin($before->{apiurl}) ne origin($effective->{apiurl})) {
            my @required = signature(\%own) eq 'RSA' ? qw(merchant_private_key platform_public_key) : ('key');
            die "Specify credentials for the new gateway\n" if grep { !length($form->{$_} // '') } @required;
        }
        validate($effective) if keys %$effective;
        my $row = $entries->{$id} ||= {paysystem => 'epay', payment_url => '/shm/pay_systems/epay.cgi'};
        apply_public($row, $main, \@fields, $effective, $form);
        die "Missing merchant\n" if $row->{show_for_client} && !keys %$effective;
        $row->{fields} = \@fields unless $id eq 'epay';
        if ($id eq 'epay') {
            for my $copy_id (grep { $_ ne 'epay' && ours($entries, $_) } keys %$entries) {
                my $copy = $entries->{$copy_id};
                my $own = $accounts->{$copy_id} || {};
                die "Specify provider for independent signature\n" if signature($own) && !exists($own->{apiurl})
                    && origin($before->{apiurl}) ne origin($effective->{apiurl});
                my $account = merchant($accounts, $copy_id);
                validate($account) if keys %$account;
                apply_public($copy, $main, selection($copy, $accounts->{$copy_id}), $account, undef);
            }
        }
        save_account($db, $id, \%own) if JSON::PP->new->canonical->encode($local) ne JSON::PP->new->canonical->encode(\%own);
    }
    $db->do('UPDATE config SET value=? WHERE config.key=?', undef, JSON::PP->new->ascii->encode($entries), 'pay_systems');
    return {profile => $id, ($deleting ? 'deleted' : 'saved') => JSON::PP::true};
}
1;
