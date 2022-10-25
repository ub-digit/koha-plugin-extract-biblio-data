package Koha::Plugin::Se::Gu::Ub::ExtractBiblioData::BackgroundJob;

use Modern::Perl;

use Koha::DateUtils qw( dt_from_string );
use Koha::Patrons;

use base 'Koha::BackgroundJob';

sub job_type {
    return 'plugin_gub_extract_biblio_data';
}

sub process {
  my ($self, $args) = @_;
  my $job_progress = 0;
  $self->started_on(dt_from_string)->progress($job_progress)
    ->status('started')->store;
  my $report = {
      total_records => 1234,
      total_success => 0,
  };
  use Data::Dumper;

  print STDERR Dumper(["DEBUG", "background-job", $args]);

  my $json = $self->json;
  my $job_data = $json->decode($self->data);
  $job_data->{report} = $report;
  $self->ended_on(dt_from_string)->data($json->encode($job_data));
  $self->status('finished') if $self->status ne 'cancelled';
  $self->store;
}

sub enqueue {
    my ( $self, $args ) = @_;

    # return unless exists $args->{};

    # my @ = @{ $args->{hold_ids} };

    $self->SUPER::enqueue(
        {
            job_size => 1,
            job_args => { "foo" => "bar" },
            queue    => 'long_tasks',
        }
    );
}

1;