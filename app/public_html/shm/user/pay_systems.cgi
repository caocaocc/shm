#!/usr/bin/perl

use v5.14;

use SHM qw(:all);
my $user = SHM->new();

my $config = get_service("config", _id => 'pay_systems');
my $list = $config ? $config->get_data : {};

my @ret;

for my $item ( keys %{ $list } ) {
    my $p = $list->{ $item };

    if (ref($p) eq 'HASH' && $p->{show_for_client}) {
        my %visible = map { exists($p->{$_}) && !ref($p->{$_}) ? ($_ => $p->{$_}) : () }
            qw(name paysystem action payment_url payment_mode template template_id weight recurring internal allow_deletion);
        $visible{show_for_client} = 1;
        if ( exists $p->{template_id} ) {
            if ( my $template = get_service('template', _id => $p->{template_id} ) ) {
                $visible{template} = $template->parse();
            }
        }
        push @ret, \%visible;
    }
}

print_json( \@ret );

exit 0;
