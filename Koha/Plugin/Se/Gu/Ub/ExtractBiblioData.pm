package Koha::Plugin::Se::Gu::Ub::ExtractBiblioData;

our $debug = 0;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
use Data::Dumper;
use MARC::Record;
use C4::Context;

## Here we set our plugin version
our $VERSION = "1.0.0";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Extract Biblio Data Plugin',
    author          => 'Stefan Berndtsson',
    date_authored   => '2022-10-07',
    date_updated    => "2022-10-07",
    minimum_version => '22.05',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin extracts biblio MARC fields/subfields into a separate table '
      . 'to be able to use detailed biblio data in reports.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub after_biblio_action {
  my ($self, $params) = @_;

  my $action = $params->{action};
  my $biblio = $params->{biblio};
  my $biblionumber = $params->{biblio_id};

  my $fieldlist = $self->retrieve_data('fieldlist');
  my $fields = parse_fieldlist($fieldlist);

  my $tablename = $self->setup();

  if(!$tablename) { return; }

  my $dbh = C4::Context->dbh;
  my $insert_query = build_insert_query($dbh, $tablename);
  my $delete_query = build_delete_query($dbh, $tablename);

  $dbh->begin_work;
  if($action eq "create" || $action eq "modify") {
    delete_all_for_biblio($delete_query, $biblionumber);
    extract_from_record($insert_query, $biblionumber, $fields, $biblio);
  }
  if($action eq "delete") {
    delete_all_for_biblio($delete_query, $biblionumber);
  }
  $dbh->commit;
}

sub cronjob_nightly {
  my ($self) = @_;

  $self->extract_from_all_records();
}

# sub tool {
#   my ( $self, $args ) = @_;
# 
#    $self->extract_from_all_records();
#   $self->go_home();
# }

sub extract_from_all_records {
  my ($self) = @_;

  my $biblios = Koha::Biblios->search();
  my $fieldlist = $self->retrieve_data('fieldlist');
  my $fields = parse_fieldlist($fieldlist);
  my $tablename = $self->setup();

  if(!$tablename) { return; }

  my $dbh = C4::Context->dbh;
  my $insert_query = build_insert_query($dbh, $tablename);
  my $delete_query = build_delete_query($dbh, $tablename);

  my $bibcnt = 0;

  $dbh->begin_work;

  while(my $biblio = $biblios->next) {
    my $biblionumber = $biblio->biblionumber;
    delete_all_for_biblio($delete_query, $biblionumber);
    extract_from_record($insert_query, $biblionumber, $fields, $biblio);
    $bibcnt++;
    if($bibcnt >= 1000) {
      $dbh->commit;
      $bibcnt = 0;
      $dbh->begin_work;
    }
  }

  $dbh->commit;
}

sub build_insert_query {
  my ($dbh, $tablename) = @_;

  my $tablename_sql = $dbh->quote_identifier($tablename);
  my $sth = $dbh->prepare(
      "INSERT INTO $tablename_sql
      (biblionumber, pos, label, tag, part, value)
        VALUES (?,?,?,?,?,?)"
  );

  return $sth;
}

sub build_delete_query {
  my ($dbh, $tablename) = @_;

  my $tablename_sql = $dbh->quote_identifier($tablename);
  my $sth = $dbh->prepare(
      "DELETE FROM $tablename_sql WHERE biblionumber = ?"
  );

  return $sth;
}

sub extract_from_record {
  my ($insert_query, $biblionumber, $fields, $biblio) = @_;
  my $record = $biblio->metadata->record;
  foreach my $fieldspec (@$fields) {
    my $field = $fieldspec->{field};
    my $label = $fieldspec->{label};
    if($field->{all} && $field->{type} eq "controlfield") {
      store_complete_controlfield($insert_query, $biblionumber, $label, $field->{tag}, $record);
    }
    if($field->{all} && $field->{type} eq "datafield") {
      store_complete_datafield($insert_query, $biblionumber, $label, $field->{tag}, $record);
    }
    if(!$field->{all} && $field->{type} eq "controlfield") {
      store_partial_controlfield($insert_query, $biblionumber, $label, $field->{tag}, $field->{from}, $field->{to}, $record);
    }
    if(!$field->{all} && $field->{type} eq "datafield") {
      store_partial_datafield($insert_query, $biblionumber, $label, $field->{tag}, $field->{subfields}, $record);
    }
  }
}

sub store_complete_controlfield {
  my ($insert_query, $biblionumber, $label, $tag, $record) = @_;
  my $value;
  my $pos;
  if($tag eq "leader") {
    $pos = 0;
    $value = $record->field()
  } else {
    $pos = int($tag);
    my $field = $record->field($tag);
    if(!$field) { return; }
    $value = $field->data();
  }

  print STDERR "DEBUG (COMPLETE/CONTROL): $pos: $value\n" if $debug;
  insert_row($insert_query, $biblionumber, $pos, $tag, $label, undef, $value);
}

sub store_partial_controlfield {
  my ($insert_query, $biblionumber, $label, $tag, $from, $to, $record) = @_;
  my $value;
  my $pos;
  if($tag eq "leader") {
    $pos = 0;
    $value = $record->leader()
  } else {
    $pos = int($tag);
    my $field = $record->field($tag);
    if(!$field) { return; }
    $value = $field->data();
  }

  my $startindex = $from;
  my $length = $to - $from + 1;

  $value = substr($value, $startindex, $length);
  print STDERR "DEBUG (PARTIAL/CONTROL): $pos: ${tag}, ${from}-${to}, $value\n" if $debug;  
  insert_row($insert_query, $biblionumber, $pos, $label, $tag, "${from}-${to}", $value);
}

sub store_complete_datafield {
  my ($insert_query, $biblionumber, $label, $tag, $record) = @_;

  my $pos = 0;
  foreach my $field ($record->fields()) {
    $pos++;
    if($field->tag eq $tag) {
      my @subfields;

      foreach my $subfield ($field->subfields()) {
        push(@subfields, $subfield->[1]);
      }
      my $value = join(" ", @subfields);
      print STDERR "DEBUG (COMPLETE/DATA): ${pos}: ${tag}, ${value}\n" if $debug;
      insert_row($insert_query, $biblionumber, $pos, $label, $tag, undef, $value);
    }
  }
}

sub store_partial_datafield {
  my ($insert_query, $biblionumber, $label, $tag, $subs, $record) = @_;
  my $subs_str = join("", @$subs);

  my $pos = 0;
  foreach my $field ($record->fields()) {
    $pos++;
    if($field->tag eq $tag) {
      my @subfields;

      foreach my $sub (@$subs) {
        my @list = $field->subfield($sub);
        push(@subfields, join(" ", @list));
      }

      my $value = join(" ", @subfields);
      print STDERR "DEBUG (PARTIAL/DATA): ${pos}: ${tag}, ${subs_str}, ${value}\n" if $debug;
      if($value ne "") {
        insert_row($insert_query, $biblionumber, $pos, $label, $tag, $subs_str, $value);
      }
    }
  }
}

sub parse_fieldlist {
  my ($fieldlist) = @_;

  my @fieldrows = split(/\n/, $fieldlist);
  my @fields;
  foreach my $row (@fieldrows) {
    my $parsed_row = parse_fieldrow($row);
    if($parsed_row) {
      push(@fields, $parsed_row);
    }
  }

  return \@fields;
}

sub parse_fieldrow {
  my ($row) = @_;

  if($row =~ /^\s*#/) { return undef; }
  if($row =~ /^\s*$/) { return undef; }

  my $fielddata;
  my $label;
  if($row =~ /^([^:]+):(.*)$/) {
    $fielddata = $1;
    $label = $2;
  } else {
    $fielddata = $row;
    $label = $row;
  }

  $fielddata =~ s/^\s*//;
  $fielddata =~ s/\s*$//;
  $label =~ s/^\s*//;
  $label =~ s/\s*$//;

  my $field = parse_field($fielddata);

  return {
    label => $label,
    field => $field
  }
}

sub parse_field {
  my ($data) = @_;

  if($data =~ /^(00\d)$/) {
    return {
      tag => $1,
      type => "controlfield",
      all => 1
    }
  }
  if($data =~ /^(00\d)_\/(\d+)$/) {
    return {
      tag => $1,
      type => "controlfield",
      all => 0,
      from => $2,
      to => $2
    }
  }
  if($data =~ /^(00\d)_\/(\d+)-(\d+)$/) {
    return {
      tag => $1,
      type => "controlfield",
      all => 0,
      from => $2,
      to => $3
    }
  }
  if($data =~ /^(\d\d\d)$/) {
    return {
      tag => $1,
      type => "datafield",
      all => 1
    }
  }
  if($data =~ /^(\d\d\d)([0-9a-zA-Z]+)$/) {
    my @subfields = split(//, $2);
    return {
      tag => $1,
      type => "datafield",
      all => 0,
      subfields => \@subfields
    }
  }
  if($data =~ /^(leader|ldr|LDR)$/) {
    return {
      tag => "leader",
      type => "controlfield",
      all => 1
    }
  }
  if($data =~ /^(leader|ldr|LDR)_\/(\d+)$/) {
    return {
      tag => "leader",
      type => "controlfield",
      all => 0,
      from => $2,
      to => $2
    }
  }
  if($data =~ /^(leader|ldr|LDR)_\/(\d+)-(\d+)$/) {
    return {
      tag => "leader",
      type => "controlfield",
      all => 0,
      from => $2,
      to => $3
    }
  }

  return undef;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            tablename => $self->retrieve_data('tablename'),
            create_on_use => $self->retrieve_data('create_on_use'),
            fieldlist => $self->retrieve_data('fieldlist'),
        );
        print $cgi->header(-charset => 'utf-8' );
        print $template->output();
    }
    else {
        $self->store_data(
            {
                tablename => $cgi->param('tablename'),
                create_on_use => $cgi->param('create_on_use'),
                fieldlist => $cgi->param('fieldlist'),
            }
        );
        $self->go_home();
    }
}

sub setup {
    my ($self) = @_;
    my $tablename = $self->retrieve_data('tablename');
    my $create_on_use = $self->retrieve_data('create_on_use');

    $self->create_table_if_missing($tablename, $create_on_use);

    return $tablename;
}

sub insert_row {
  my ($insert_query, $biblionumber, $pos, $label, $tag, $part, $value) = @_;

  $insert_query->execute($biblionumber, $pos, $label, $tag, $part, $value);
}

sub delete_all_for_biblio {
  my ($delete_query, $biblionumber) = @_;

  $delete_query->execute($biblionumber);
}

sub table_exists {
    my ($self) = @_;

    my $tablename = $self->retrieve_data('tablename');

    if(!$tablename) {
        return 0;
    }
    
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_name = ?");
    $sth->execute($tablename);

    my $row = $sth->fetchrow_hashref;
    if($row->{count} == 1) {
        return 1;
    } else {
        return 0;
    }
}

sub create_table_if_missing {
    my ($self, $tablename, $create_table_if_missing) = @_;

    # If we shouldn't try to create table or if no tablename is provided, or if table exists, exit.
    if(!$create_table_if_missing || !$tablename || $self->table_exists()) {
        return;
    }

    # Ok, everything says table should be created.
    my $dbh = C4::Context->dbh;
    my $tablename_sql = $dbh->quote_identifier($tablename);
    my $sth = $dbh->prepare(<<"END_SQL");
    CREATE TABLE $tablename_sql (
      biblionumber int(11),
      pos int(11),
      label varchar(80),
      tag varchar(10),
      part varchar(80),
      value longtext
    )
END_SQL
    $sth->execute();
}

1;
