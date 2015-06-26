#!/usr/bin/env perl

# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveAssemblyLoading::HiveSetMetaAndSeqRegionSynonym;

use strict;
use warnings;
use feature 'say';

use Bio::EnsEMBL::Utils::Exception qw(warning throw);
use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');

sub fetch_input {
  my $self = shift;

  unless($self->param('core_db')) {
    throw("core_db flag not passed into parameters hash. The core db to load the assembly info ".
          "into must be passed in with write access");
  }

  unless($self->param('enscode_dir')) {
    throw("enscode_dir flag not passed into parameters hash. You need to specify where your code checkout is");
  }

  return 1;
}

sub run {
  my $self = shift;

  say "Loading meta information seq region synonyms into reference db\n";
  my $core_db = Bio::EnsEMBL::DBSQL::DBAdaptor->new(%{$self->param('core_db')});
  my $genebuilder_id = $self->param('genebuilder_id');
  my $enscode_dir = $self->param('enscode_dir');
  my $primary_assembly_dir_name = $self->param('primary_assembly_dir_name');
  my $output_path = $self->param('output_path');
  my $path_to_files = $output_path."/".$primary_assembly_dir_name;
  my $chromo_present = $self->param('chromosomes_present');

  say "\nBacking up meta and seq_region tables...";
  backup_tables($path_to_files,$self->param('core_db'));
  say "\nBackup of tables complete\n";

  say "Setting meta information in meta table...\n";
  set_meta($core_db,$genebuilder_id,$path_to_files);
  say "\nMeta table insertions complete\n";

  say "Setting seq region synonyms...\n";
  set_seq_region_synonyms($core_db,$path_to_files,$chromo_present);
  say "\nSeq region synonyms inserted\n";

  say "\nFinished updating meta table and setting seq region synonyms";
  return 1;
}

sub write_output {
  my $self = shift;

  return 1;
}


sub backup_tables {
  my ($path_to_files,$core_db_hash) = @_;

  my $dbhost = $core_db_hash->{'-host'};
  my $dbport = $core_db_hash->{'-port'};
  my $dbuser = $core_db_hash->{'-user'};
  my $dbpass = $core_db_hash->{'-pass'};
  my $dbname = $core_db_hash->{'-dbname'};

  for my $table ('seq_region','meta') {
    my $backup_file = $path_to_files."/".$table.".".time().".sql";
    my $cmd = "mysqldump".
              " -h".$dbhost.
              " -P".$dbport.
              " -u".$dbuser.
              " -p".$dbpass.
              " ".$dbname.
              " ".$table.
              " > ".$backup_file;
    my $return = system($cmd);
    if($return) {
      throw("mysqldump to backup ".$table." table failed. Commandline used:\n".$cmd);
    } else {
      say $table." table backed up in the following location:\n".$backup_file;
    }
  }
}

sub set_meta {
  my ($core_db,$genebuilder_id,$path_to_files) = @_;

  my $meta_adaptor = $core_db->get_MetaContainerAdaptor;
  $meta_adaptor->store_key_value('genebuild.id', $genebuilder_id);
  say "Inserted into meta:\ngenebuild.id => ".$genebuilder_id;
  $meta_adaptor->store_key_value('marker.priority', 1);
  say "Inserted into meta:\nmarker.priority => 1";
  $meta_adaptor->store_key_value('assembly.coverage_depth', 'high');
  say "Inserted into meta:\nassembly.coverage_depth => high";

  unless(-e $path_to_files."/assembly_report.txt") {
    throw("Could not find the assembly_report.txt file. Path checked:\n".$path_to_files."/assembly_report.txt");
  }

  open(IN,$path_to_files."/assembly_report.txt");
  my $description_defined = 0;
  my $assembly_name;
  while (my $line = <IN>) {
    if($line !~ /^#/) {
      next;
    } elsif($line =~ /^#\s*Date:\s*(\d+)-(\d+)-\d+/) {
      $meta_adaptor->store_key_value('assembly.date', $1.'-'.$2);
      say "Inserted into meta:\nassembly.date => ".$1.'-'.$2;
    } elsif($line =~ /^#\s*Description:\s*(\S+)/) {
      $description_defined = 1;
      $meta_adaptor->store_key_value('assembly.name', $1);
      say "Inserted into meta:\nassembly.name => ".$1;
   } elsif($line =~ /^#\s*Assembly Name:\s*(\S+)/) {
      $assembly_name = $1;
      $meta_adaptor->store_key_value('assembly.default', $assembly_name);
      say "Inserted into meta:\nassembly.default => ".$assembly_name;
    } elsif($line =~ /^#\s*GenBank Assembly ID:\s*(\S+)/) {
      $meta_adaptor->store_key_value('assembly.accession', $1);
      say "Inserted into meta:\nassembly.accession => ".$1;
      $meta_adaptor->store_key_value('assembly.web_accession_source', 'NCBI');
      say "Inserted into meta:\nassembly.web_accession_source => NCBI";
      $meta_adaptor->store_key_value('assembly.web_accession_type', 'GenBank Assembly ID');
      say "Inserted into meta:\nassembly.web_accession_type => GenBank Assembly ID";
    }
  }

  close IN;

  unless($description_defined) {
    $meta_adaptor->store_key_value('assembly.name', $assembly_name);
    say "Inserted into meta:\nassembly.name => ".$assembly_name;
  }

}

sub set_seq_region_synonyms {
  my ($core_db,$path_to_files,$chromo_present) = @_;

  if($chromo_present) {
    unless(-e $path_to_files."/chr2acc") {
      throw("Could not find chr2acc file. No chromosome synonyms loaded. Expected location:\n".$path_to_files."/chr2acc");
    }

    open(IN,$path_to_files."/chr2acc");
    my $sth_select = $core_db->dbc->prepare('SELECT sr.seq_region_id FROM seq_region sr, coord_system cs WHERE cs.coord_system_id = sr.coord_system_id AND sr.name = ? AND cs.rank = 1');
    my $sth_insdc = $core_db->dbc->prepare('SELECT external_db_id FROM external_db WHERE db_name = "INSDC"');
    $sth_insdc->execute();
    my ($insdc_db_id) = $sth_insdc->fetchrow_array;

    my $sth_insert = $core_db->dbc->prepare('INSERT INTO seq_region_synonym (seq_region_id, synonym, external_db_id) VALUES(?, ?, ?)');
    my $sth_update = $core_db->dbc->prepare('UPDATE seq_region set name = ? WHERE seq_region_id = ?');
    my $insert_count = 0;
    while(my $line = <IN>) {
      if($line =~ /^#/) {
        next;
      }
      my ($synonym, $seq_region_name) = $line =~ /(\w+)\s+(\S+)/;
      $sth_select->bind_param(1, $seq_region_name);
      $sth_select->execute();
      my ($seq_region_id) = $sth_select->fetchrow_array();
      $sth_insert->bind_param(1, $seq_region_id);
      $sth_insert->bind_param(2, $seq_region_name);
      $sth_insert->bind_param(3, $insdc_db_id);
      $sth_insert->execute();
      $sth_update->bind_param(1, $synonym);
      $sth_update->bind_param(2, $seq_region_id);
      $sth_update->execute();
      $insert_count++;
    }
    close(IN);

    if($insert_count == 0) {
      throw("The insert/update count after parsing chr2acc was 0, this is probably wrong. File used:\n".$path_to_files."/chr2acc");
    }

    say "\nInserted into seq_region_synonym and updated seq_region based on chr2acc. Total inserts/updates: ".$insert_count;
  } else {
    say "The chromosomes_present parameter was not set to 1 in the config, so assuming there are no chromosomes";
  }

  foreach my $file ('component_localID2acc', 'scaffold_localID2acc') {
    unless(-e $path_to_files."/".$file) {
      throw("Could not find ".$file." file. No synonyms loaded. Expected location:\n".$path_to_files."/".$file);
    }

    open(IN,$path_to_files."/".$file);
    my $sth_select = $core_db->dbc->prepare('SELECT seq_region_id FROM seq_region WHERE name = ?');
    my $sth_insert = $core_db->dbc->prepare('INSERT INTO seq_region_synonym (seq_region_id, synonym) VALUES(?, ?)');
    my $insert_count = 0;
    while (my $line = <IN>) {
      if ($line =~ /^#/) {
        next;
      }

      my ($synonym, $seq_region_name) = $line =~ /(\S+)\s+(\S+)/;
      if($synonym eq 'na') {
        $synonym = $seq_region_name;
      }
      $sth_select->bind_param(1, $seq_region_name);
      $sth_select->execute();
      my ($seq_region_id) = $sth_select->fetchrow_array();
      $sth_insert->bind_param(1, $seq_region_id);
      $sth_insert->bind_param(2, $synonym);
      $sth_insert->execute();
      $insert_count++;
    }

    if($insert_count == 0) {
      throw("The insert/update count after parsing ".$file." was 0, this is probably wrong. File used:\n".$path_to_files."/".$file);
    }

    say "\nInserted into seq_region_synonym and updated seq_region based on ".$file.". Total inserts/updates: ".$insert_count;
    say "You will need to update the external_db_id for the synonyms of scaffold or contigs!\n";
  }

}

1;
