use DBI;
use DBD::mysql;


# backend_mysql_create_extra_tables()
# The mbzdb plugins use a basic key-value table to hold information such as settings.
# @see mbz_set_key(), mbz_get_key().
# @return Passthru from $dbh::do().
sub backend_mysql_create_extra_tables {
	# no need to if the table already exists
	return 1 if(mbz_table_exists("kv"));

	$sql = "CREATE TABLE kv (" .
	       "name varchar(255) not null primary key," .
	       "value text" .
	       ")";
	$sql .= " engine=$g_mysql_engine" if($g_mysql_engine ne '');
	$sql .= " tablespace $g_tablespace" if($g_tablespace ne "");
	return mbz_do_sql($sql);
}


# mbz_escape_entity($entity)
# Wnen dealing with table and column names that contain upper and lowercase letters some databases
# require the table name to be encapsulated. MySQL uses back-ticks.
# @return A new encapsulated entity.
sub backend_mysql_escape_entity {
	my $entity = $_[0];
	return "`$entity`";
}


# backend_mysql_get_column_type($table_name, $col_name)
# Get the MySQL column type.
# @param $table_name The name of the table.
# @param $col_name The name of the column to fetch the type.
# @return MySQL column type.
sub backend_mysql_get_column_type {
	my ($table_name, $col_name) = @_;
	
	my $sth = $dbh->prepare("describe `$table_name`");
	$sth->execute();
	while(@result = $sth->fetchrow_array()) {
		return $result[1] if($result[0] eq $col_name);
	}
	
	return "";
}


# mbz_index_exists($index_name)
# Check if an index already exists.
# @param $index_name The name of the index to look for.
# @return 1 if the index exists, otherwise 0.
sub backend_mysql_index_exists {
	my $index_name = $_[0];
	
	# yes I know this is a highly inefficent way to do it, but its simple and is only called on
	# schema changes.
	my $sth = $dbh->prepare("show tables");
	$sth->execute();
	while(@result = $sth->fetchrow_array()) {
		my $sth2 = $dbh->prepare("show indexes from `$result[0]`");
		$sth2->execute();
		while(@result2 = $sth2->fetchrow_array()) {
			return 1 if($result2[2] eq $index_name);
		}
	}
	
	# the index was not found
	return 0;
}

sub backend_mysql_primary_key_exists {
        my $table_name = $_[0];

        # yes I know this is a highly inefficent way to do it, but its simple and is only called on
        # schema changes.
        my $sth2 = $dbh->prepare("show indexes from `$table_name`");
        $sth2->execute();
        while(@result2 = $sth2->fetchrow_array()) {
	        return 1 if($result2[2] eq 'PRIMARY');
        }

        # the index was not found
        return 0;
}


# mbz_load_pending($id)
# Load Pending and PendingData from the downaloded replication into the respective tables. This
# function is different to mbz_load_data that loads the raw mbdump/ whole tables.
# @param $id The current replication number. See mbz_get_current_replication().
# @return Always 1.
sub backend_mysql_load_pending {
	$id = $_[0];

	# make sure there are no pending transactions before cleanup
	return -1 if(mbz_get_count($g_pending, "") ne '0');

	# perform cleanup (makes sure there no left over records in the PendingData table)
	$dbh->do("DELETE FROM `$g_pending`");

	# load Pending and PendingData
	print localtime() . ": Loading pending tables... ";
	mbz_do_sql(qq|
		LOAD DATA LOCAL INFILE 'replication/$id/mbdump/$g_pendingfile'
		INTO TABLE `$g_pending`
	|);
	mbz_do_sql(qq|
		LOAD DATA LOCAL INFILE 'replication/$id/mbdump/$g_pendingdatafile'
		INTO TABLE `$g_pendingdata`
	|);
	print "Done\n";
	
	# PLUGIN_beforereplication()
	foreach my $plugin (@g_active_plugins) {
		my $function_name = "${plugin}_beforereplication";
		(\&$function_name)->($id) || die($!);
	}
	
	return 1;
}


# backend_mysql_update_index()
# Attemp to pull as much relevant information from CreateIndexes.sql as we can. MySQL does not
# support function indexes so we will skip those. Any indexes created already on the database will
# be left intact.
# @return Always 1.
sub backend_mysql_update_index {
	open(SQL, "replication/CreateIndexes.sql");
	chomp(my @lines = <SQL>);
	
	my $index_size = 200;
	foreach my $line (@lines) {
		$line = mbz_trim($line);
		my $pos_index = index($line, 'INDEX ');
		my $pos_on = index($line, 'ON ');
		
		# skip blank lines, comments, psql settings and lines that arn't any use to us.
		next if($line eq '' || substr($line, 0, 2) eq '--' || substr($line, 0, 1) eq "\\" ||
		        $pos_index < 0);
		        
		# skip function-based indexes.
		next if($line =~ /.*\(.*\(.*\)\)/);
		
		# get the names
		my $index_name = mbz_trim(substr($line, $pos_index + 6, index($line, ' ', $pos_index + 7) -
		                       $pos_index - 6));
		my $table_name = mbz_trim(substr($line, $pos_on + 3, index($line, ' ', $pos_on + 4) -
		                       $pos_on - 3));
		my $cols = substr($line, index($line, '(') + 1, index($line, ')') - index($line, '(') - 1);
		
		# PostgreSQL will put double-quotes around some entity names, we have to remove these
		$index_name = mbz_remove_quotes($index_name);
		$table_name = mbz_remove_quotes($table_name);
		
		# see if the index aleady exists, if so skip
		next if(mbz_index_exists($index_name));
		
		# split and clean column names. this is also a good time to find out there type, if its
		# TEXT then MySQL requires and index length.
		my @columns = split(",", $cols);
		for(my $i = 0; $i < @columns; ++$i) {
			if((backend_mysql_get_column_type($table_name, mbz_trim($columns[$i])) eq 'text') || (backend_mysql_get_column_type($table_name, mbz_trim($columns[$i])) eq 'varchar')  ) {
				$columns[$i] = "`" . mbz_trim(mbz_remove_quotes($columns[$i])) . "`($index_size)";
			} else {
				$columns[$i] = "`" . mbz_trim(mbz_remove_quotes($columns[$i])) . "`";
			}
		}
		
		# now we construct the index back together in case there was changes along the way
		$new_line = substr($line, 0, $pos_index) . "INDEX `$index_name` ON `$table_name` (";
		$new_line .= join(",", @columns) . ")";
		
		# all looks good so far ... create the index
		print "$new_line\n";
		my $success = mbz_do_sql($new_line);
		
		# if the index fails we will run it again as non-unique
		if(!$success) {
			$new_line =~ s/UNIQUE//;
			mbz_do_sql($new_line);
		}
	}
	close(SQL);
	
	open(SQL, "replication/CreatePrimaryKeys.sql");
	chomp(my @lines = <SQL>);
	foreach my $line (@lines) {
		$line = mbz_trim($line);

		# skip blank lines and single bracket lines
		next if($line eq "" || substr($line, 0, 2) eq "--" || substr($line, 0, 1) eq "\\" ||
		        substr($line, 0, 5) eq "BEGIN");

		my $pos_table = index($line, 'TABLE ');
		my $pos_add = index($line, 'ADD ');
		my $pos_index = index($line, 'CONSTRAINT ');

		my $table_name = mbz_trim(substr($line, $pos_table + length('TABLE '), $pos_add - $pos_table - length('TABLE ')));
		my $index_name = mbz_trim(substr($line, $pos_index + 11, index($line, ' ', $pos_index + 12) -
				                  $pos_index - 11));
		my $cols = substr($line, index($line, '(') + 1, index($line, ')') - index($line, '(') - 1);

		# no need to create the index if it already exists
		next if(backend_mysql_primary_key_exists($table_name));

		# split and clean column names. this is also a good time to find out there type, if its
		# TEXT then MySQL requires and index length.
		my @columns = split(",", $cols);
		for(my $i = 0; $i < @columns; ++$i) {
			if((backend_mysql_get_column_type($table_name, mbz_trim($columns[$i])) eq 'text')  || (backend_mysql_get_column_type($table_name, mbz_trim($columns[$i])) eq 'varchar') ) {
				$columns[$i] = "`" . mbz_trim(mbz_remove_quotes($columns[$i])) . "`($index_size)";
			} else {
				$columns[$i] = "`" . mbz_trim(mbz_remove_quotes($columns[$i])) . "`";
			}
		}

		# now we construct the index back together in case there was changes along the way
		$new_line = "ALTER TABLE `$table_name` ADD CONSTRAINT `$index_name` PRIMARY KEY  (";
		$new_line .= join(",", @columns) . ")";

		print "$new_line\n";
		mbz_do_sql($new_line, 'nodie');
	}
	close(SQL);

	print "Done\n";
	return 1;
}

# backend_mysql_update_foreignkey()
# Attemp to pull as much relevant information from CreateFKConstraints.sql as we can.
# @return Always 1.
sub backend_mysql_update_foreignkey {
	open(SQL, "replication/CreateFKConstraints.sql");
	chomp(my @lines = <SQL>);
	my $index_name = "", $table_name = "", $columns = [], $foreign_table_name = "", $foreign_columns = [];

	foreach my $line (@lines) {
		# skip blank lines and single bracket lines
		next if($line eq "" || substr($line, 0, 2) eq "--" || substr($line, 0, 1) eq "\\" ||
		        substr($line, 0, 5) eq "BEGIN");

		if(index($line, 'CONSTRAINT ') > 0) {
			my $pos_index = index($line, 'CONSTRAINT ');
			$index_name = mbz_trim(substr($line, $pos_index + length('CONSTRAINT ')));
		}
		if(index($line, 'TABLE ') > 0) {
			my $pos_index = index($line, 'TABLE ');
			$table_name = mbz_trim(substr($line, $pos_index + length('TABLE ')));
		}
		if(index($line, 'REFERENCES ') > 0) {
			my $pos_index = index($line, 'REFERENCES ');
			$foreign_table_name = mbz_trim(substr($line, $pos_index + length("REFERENCES "), index($line, '(') - $pos_index - length("REFERENCES ")));
            my $cols = substr($line, index($line, '(') + 1, index($line, ')') - index($line, '(') - 1);
		    @foreign_columns = split(",", $cols);
		    for(my $i = 0; $i < @columns; ++$i) {
			    $foreign_columns[$i] = "`" . mbz_trim(mbz_remove_quotes($foreign_columns[$i])) . "`";
		    }
		}
		if(index($line, 'FOREIGN KEY ') > 0) {
            my $cols = substr($line, index($line, '(') + 1, index($line, ')') - index($line, '(') - 1);
		    @columns = split(",", $cols);
		    for(my $i = 0; $i < @columns; ++$i) {
			    $columns[$i] = "`" . mbz_trim(mbz_remove_quotes($columns[$i])) . "`";
		    }
		}

		if(index($line, ';') > 0) {
			next if(backend_mysql_index_exists($index_name));
            $sql = "ALTER TABLE `$table_name` ADD CONSTRAINT `$index_name`";
            $sql .= " FOREIGN KEY (" . join(",", @columns) . ")";
            $sql .= " REFERENCES `$foreign_table_name`(" . join(",", @foreign_columns) . ")";

			print "$sql\n";
			mbz_do_sql($sql, 'nodie');
		}
	}
	close(SQL);
	
	print "Done\n";
	return 1;
}

# be nice
return 1;
