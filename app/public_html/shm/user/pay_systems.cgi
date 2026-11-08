#!/usr/bin/perl

use v5.14;

use SHM qw(:all);
my $user = SHM->new();

my $config = get_service("config", _id => 'pay_systems');
my $list = $config ? $config->get_data : {};

my @ret;

for my $item ( keys %{ $list } ) {
    my $p = $list->{ $item };
    next unless ref($p) eq 'HASH';
    $p = get_service('Pay::Local')->profile($item, $p);

    if ( $p->{ show_for_client } ) {
        # This legacy endpoint is also available to ordinary customers. Keep
        # merchant credentials in the private configuration, as the v1 payment
        # list does; only the public checkout fields belong in this response.
        my %public = map { $_ => $p->{$_} }
            grep { exists $p->{$_} && !ref $p->{$_} }
            qw(paysystem name weight payment_url shm_url action payment_mode
               template_id template amount forecast user_id);
        for my $flag (qw(show_for_client internal recurring allow_recurring allow_deletion)) {
            $public{$flag} = $p->{$flag} ? 1 : 0 if exists $p->{$flag};
        }
        if ( defined($p->{template_id}) && !ref($p->{template_id}) ) {
            if ( my $template = get_service('template', _id => $p->{template_id} ) ) {
                my $rendered = $template->parse();
                $public{template} = $rendered unless ref $rendered;
            }
        }
        push @ret, \%public;
    }
}

print_json( \@ret );

exit 0;
