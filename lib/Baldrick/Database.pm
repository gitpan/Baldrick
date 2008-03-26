package Baldrick::Database;

# Wrapper for database handle with functions for doing queries easily.

use strict;
use DBI;
use Baldrick::Util;
use Time::HiRes qw(gettimeofday tv_interval);

our @ISA = qw(Baldrick::Turnip);

# table info cache 
our %tabledefs;	# = ( table1 => {field1=>def,field2=>def,...}, table2=>... )

sub new 
{
	my ($class, %args) = @_;
    my $self = {};
    bless ($self, $class);
    $self->init(%args) if (%args);
    return $self;
}

sub init
{
    my ($self, %args) = @_;
    $self->SUPER::init(%args, 
        copyRequired => [ qw(config name) ],
        copyDefaults => {  url => '' } 
    );         
    
	return $self;
}

sub DESTROY
{
	my ($self) = @_;
	$self->close() unless ($self->{_FINISHED});	
}

sub finish
{
	return close(@_);
}

sub close
{
	my ($self) = @_;
	if ($self->{_dbh})
	{
		$self->{_dbh}->disconnect();
		delete $self->{_dbh};
	}
	
	$self->{_FINISHED} = 1;
	return 0;
}

sub getHandle
{
	my ($self) = @_;

    $self->markTime();

	return $self->{_dbh} if ($self->{_dbh});
	$self->setError("Database handle missing or closed", fatal => 1, uplevel => 1);
}

sub getName
{
	my ($self) = @_;
	return $self->{_name};
}

sub getConnectString
{
	my ($self) = @_;
	return $self->{_connect};
}

sub open # ( %args )
# opt name  => keyword for config section
# opt connect => DBI-style url to connect to.
# opt username =>  
# opt password =>
# opt softfail => 0 | 1  -- if softfail is true, then errors won't cause abort (by default failure to open is fatal)
{
	my ($self, %args) = @_;

    $self->{_name} ||= $args{name};
    $self->{_connect} = $args{connect} || $self->getConfig('connect') || $self->abort(
        "Database config for '$self->{_name}': missing 'connect'");
	
	my $username = $args{username} || $self->getConfig("username");
	my $password = $args{password} || $self->getConfig("password");
	
	my $dbh = DBI->connect($self->{_connect}, $username, $password);
	
	if ($dbh)
	{
		$self->{_dbh} = $dbh;
        $self->{_timeOpened} = [ Time::HiRes::gettimeofday() ]; 
		return 0;
	} else {
		# Default to fatal=>1 unless we were called with 'softfail'
		return $self->setError("Failed to connect to database.",
            privmsg => "failed to connect to database $self->{_name} at $self->{_connect}: "
            . DBI->errstr, 
            fatal => !$args{softfail}
        );
	}
}

sub isFresh
{
    my ($self) = @_;

    my $now =  [ Time::HiRes::gettimeofday() ];
   
    if (my $to = $self->{_timeOpened})
    {
        my $max = $self->getConfig("lifespan", defaultvalue => 120);
        if ($max && (tv_interval($to, $now) > $max))
        {
            return 0;   # TOO OLD
        } 
    } 

    my $tacc = $self->{_timeAccessed};
    if ($tacc)
    {
        my $max = $self->getConfig("maxidle", defaultvalue => 60);
        if ($max && (tv_interval($tacc, $now) > $max))
        {
            return 0;   # IDLE TOO LONG
        } 
    } 
   
    if ($tacc > 10) # more than 10 seconds since last use? don't trust it.
    {
        my $dbh = $self->{_dbh};
        if ($dbh->can('ping'))
        {
            return 0 if ($dbh->ping() < 1);
        } 
    }  

    return 1;
}

sub markTime
{
    my ($self) = @_;
    $self->{_timeAccessed} = [ Time::HiRes::gettimeofday() ];
}

### QUERYING METHODS ######################################################

sub execsql # ( $sql, %args ) 
# simple wrapper for dbh->do
{
	my ($self, $sql, %args) = @_;
	return ( $self->getHandle()->do($sql) );
}

sub query # (%args) return LISTREF or HASHREF
# arg sql => ... REQUIRED; can have positional parameters like ?,?,?...
# arg sqlargs => [ positional-parameter-list ] 
# arg for_arg_lists => [ list1, list2, list3 ] - repeat query for each arg list
# substitute => 0|1 substitute placeholders for /LIST/
#RESULTS: return as LISTREF by default; can also be put into hash by some key.
# arg results => \@listref
# arg resulthash => \%hashref
# arg keyfield => 'fieldname'  (required if using resulthash).
# arg onerecord => 0 | 1 (return just one rec, not array or hash)
{
	my ($self, %args) = @_;
	my $dbh = $self->getHandle();
	
    my $sql = requireArg(\%args, 'sql');

	# if 'substitute' is present, then replace /LIST/ in sql statement with a
	# list of '?,' placeholders of the same length as 'args'.
	if ($args{substitute})
	{
		$sql = $self->substitutePlaceholders(%args);
	}
	
	### PREPARE.
    $self->mutter("Running SQL: $sql", always => 1) if ($args{debug});
	my $sth = $dbh->prepare($sql);
	$self->setError("error in prepare(): " . $dbh->errstr, 
        fatal => 1, uplevel => 1) if (!$sth);
	
	### EXECUTE.
	my $rc = -1;

	$sth->{RaiseError} = 'On';
    my $cloakError = $self->{_publicErrors} ? 0 : 1;

    my @arglists;

	if (my $sa = $args{sqlargs} )
	{
        $self->fatalError("sqlargs must be array ") unless ref($sa);
        $self->mutter("SQL Args: " . join(", ", @$sa), always => 1) if ($args{debug});
        push (@arglists, $sa);
	} elsif (my $sa = $args{args}) {
        $self->whinge("Database::Query:  use of deprecated 'args'", uplevel => 2);
        $self->fatalError("sqlargs must be array ") unless ref($sa);
        push (@arglists, $sa);
    } elsif (my $al = $args{for_arg_lists}) {
        push (@arglists, @$al);
    } else {
         $self->whinge("Database::Query:  failed to use 'sqlargs'", uplevel => 2);
    }

    # Always exec at least once.
    if ($#arglists < 0)
    {
        push (@arglists, []);
    } 

	eval {
        foreach my $sa (@arglists)
        {
            $self->mutter("executing with args: " . join(", ", @$sa));
            $rc = $sth->execute(@$sa);
        } 
	};
	if ($@)
	{
		print STDERR "sql error in: $args{sql}\n";

        # if _debug is set give real error message else meaningless one, for security.
        my $msg = $@ . " in sql: $args{sql}" ;
        my $pubmsg = ($args{debug} || $self->{_debug}) ? $msg : 
            $cloakError ? "A database error has occurred." 
            : $msg;
		$self->setError($pubmsg, 
			privmsg => $msg , fatal => 1, uplevel => 1
        );
	} 	
	
	# if args{results} (a listref) is provided, append all query results to end;
	# else, just use an anon list.  
	my $res = (defined $args{results}) ? $args{results} : [];
	my $count=0;

	return $rc if ($args{nofetch});
	return $rc if ($args{sql} =~ m/^delete/i);
	return $rc if ($args{sql} =~ m/^update/i);

	# alias parameter.
	$args{resultanalyse} ||= $args{resultanalyze};

	# fetch results into $res arrayref.
	while (my $r = $sth->fetchrow_hashref())
	{
		++$count;
		if ($args{resultclass})
		{
			# print "Content-type: text/plain\n\n";
			# print "$args{resultclass}<br>\n";

			bless($r, $args{resultclass});

			if ($args{resultinit})
			{
				$r->init( @{ $args{resultinit} } );
			}
			if ($args{resultanalyse})
			{
				$r->analyse( @{ $args{resultanalyse} } );
			}
		} 
		push (@$res, $r);
	}
	
	# if resulthash/keyfield are supplied, then copy each record into the resulthash indexed
	# by whatever the value of its 'keyfield' (primary key, usually) is.
	if (defined($args{resulthash}) && defined($args{keyfield}))
	{
		foreach my $r (@$res)
		{
			my $k = $r->{ $args{keyfield} };
			$args{resulthash}->{$k} = $r;
		}
	}

	# onerecord: return only one record, not an array; 0 if empty.
	if ($args{onerecord})
	{
		return $#$res>=0 ? $res->[0] : 0;
	} 

	return $res;
}

sub insert
# required:
#   table => tablename
#   data => \%data
# optional: 
#   primarykey => fieldname
#   pksequence => sequence to allocate key field from.
#   reload => 0 | 1
#   ignore_keys => [ field list ]
{
	my ($self, %args) = @_;

    my $data = requireArg(\%args, 'data');
    my $table = requireArg(\%args, 'table');

	my $tdef = $self->getTableDefinition($args{table}, softfail => 1);
    $tdef = $data if (!$tdef);

    # arg primarykey: if present, require that this primary key be defined 
    # -- or supply one if we can.
    if (my $pk = $args{primarykey})
    {
        if (! defined($data->{$pk}))
        {
            my $seq = requireArg(\%args, 'pksequence');
            $data->{$pk} = $self->getFromSequence($seq);
        } 
    }

    # ignore some fieldnames
    my $ignore = {};
    if (my $itemp = $args{ignore_keys})
    {
        map { $ignore->{$_} = 1 } @$itemp;
    } 

    ### BUILD STATEMENT.
	my @fieldNames;
    my @fieldValues;
	foreach my $fn (sort(keys %$tdef))
	{
        next if ($ignore->{$fn});
		next unless (defined ($data->{$fn}));
        push (@fieldNames, $fn);
        push (@fieldValues, $data->{$fn});
	} 

	my $sql = sprintf("INSERT INTO %s (%s) values (%s)",
        $table, 
        join(',', @fieldNames),
        join(',', map { '?' } @fieldValues)
    );

    $self->mutter("insert(): $sql");
    $self->mutter("insert(): " . join(", ", @fieldValues));

    ## EXECUTE IT.
    if ($args{no_exec} || $args{test})
    {
        $self->mutter("EXECUTE SUPPRESSED.");
    } else {
	    my $sth = $self->prepare($sql);
	    $self->executeStatement($sth, \@fieldValues, 
            uplevel => 1 + $args{uplevel}, sql => $sql);
	    $sth->finish();
    }

    # Now reload it.
    if ($args{reload})
    {
        my $pk = requireArg(\%args, 'primarykey');
        my $rv = $self->query(
            %args,  # for resultinit, resultclass, ...
            onerecord => 1,
            sql => "select * from $table where $pk=?",
            sqlargs => [ $data->{$pk} ], 
        );
        if ($rv)
        {
            return $rv;
        } else {
            $self->setError("Could not reload record from table $table with id $data->{$pk}", 
                uplevel => 1 + $args{uplevel}, 
                fatal => !$args{softfail}
            );
        } 
    }
	return $data;
}

sub executeStatement
{
	my ($self, $sth, $parmlist, %args) = @_;
	my $rc = 0;

    if (!$sth) 
    {
        $rc = 0;    # ERROR.
    } elsif ($parmlist)
	{
		$rc = $sth->execute(@$parmlist);
	} else {
		$rc = $sth->execute();
	}

	if (!$rc)
	{
        $self->whinge("sql error in $args{sql}\n");
        $self->whinge("args: " . join(", ", @$parmlist) . "\n");
   
        my $errstr = $sth ? $sth->errstr() : $self->getHandle()->errstr(); 
		$self->setError("error executing sql: $errstr", 
            fatal => !$args{softfail}, uplevel => 1 + $args{uplevel});
	} 

	return $rc;
}

sub prepare
# wrapper for handle's prepare, return $sth
{
	my ($self, $sql) = @_;
	my $dbh = $self->getHandle();
	my $sth = $dbh->prepare($sql);
	if (! $sth)
	{
		$self->setError("Error in SQL: " . $dbh->errstr, fatal => 1);
	} 
	return $sth;
}

sub getTableDefinition
{
	my ($self, $table, %args) = @_;
	return $tabledefs{$table} if ($tabledefs{$table});

	my $dbh = $self->getHandle();

	my $out = {};
	my $sth = $dbh->prepare("select * from $table limit 1");
	if ($sth && $sth->execute())
	{
		if (my $row = $sth->fetchrow_hashref())
		{
			foreach my $k (keys %$row)
			{
				$out->{$k} = 1;
			} 
		} else {
			$self->setError("no rows in table $table", 
                fatal => $args{softfail} ? 0 : 1);
            return 0;
		}
		$sth->finish();
	} else {
		$self->setError("cannot read table $table: " . $dbh->errstr, 
			fatal => 1);
	} 

	$tabledefs{$table} = $out;
	return $out;
}

sub deleteRows
# arg table => tablename
# arg keyfield => primary key name
# arg keyvalue => primary key value
# arg where => fragment after 'WHERE' of sql.
# arg whereargs => positional parameters for WHERE part.
{
	my ($self, %args) = @_;

    my $table = _denastyIdentifier(requireArg(\%args, 'table'));

    my $whereStuff = $self->buildWhere(%args, required => 1, conjunction => 'AND');

    my $sql = sprintf("DELETE FROM %s WHERE %s", $table, $whereStuff->{whereexpr});

    $self->abort('no where expression for delete') if (!$whereStuff->{whereexpr});

    $self->mutter("delete(): $sql");
#    $self->mutter("delete(): " . join(", ", @valuelist));

    return $self->_execSQL(%args, sql => $sql, sqlargs => $whereStuff->{whereargs});

}


sub update
# arg table => tablename
# arg data => hashref of fieldname-value
# ..and one of  keyfield+keyvalue or where
# arg keyfield => primary key name
# arg keyvalue => primary key value
# arg where => fragment after 'WHERE' of sql.
# arg whereargs => positional parameters for WHERE part.
# 
# arg test => 0 | 1 - if true, just do mutter() with sql/arglist.
{
	my ($self, %args) = @_;

    my $table = _denastyIdentifier(requireArg(\%args, 'table'));

    # 'data' and 'update' arg names are equivalent
    my $update = defined($args{data}) ? 
        $args{data} : requireArg(\%args, 'update');

	if (! %$update)
	{
		return $self->whinge("Nothing to do updating $table\n");
	} 

    # Build the first part of the update statement:
    #   UPDATE table SET f1=?, f2=?
	my @valuelist;	# values to be sent as bound vars.
	my $fieldsql;		# sql
	foreach my $fn (keys %$update)
	{
		$fieldsql .= ", " if ($fieldsql);
		$fieldsql .= "$fn=?";
		push (@valuelist, $update->{$fn});
	} 

    # Now build the second half
    my $whereStuff = $self->buildWhere(%args, 
        required => 1, conjunction => 'AND');
    if (!$whereStuff->{whereexpr})
    {
        $self->abort("No WHERE expression, cannot update database.");
    } 

	my $sql = sprintf("UPDATE %s SET %s WHERE %s",
        $table, $fieldsql, $whereStuff->{whereexpr}
    );
    push (@valuelist, @{ $whereStuff->{whereargs} });

    return $self->_execSQL(%args, sql => $sql, sqlargs => \@valuelist);
}

sub _execSQL
{
    my ($self, %args) = @_;

    my $TESTING = $args{test} || 0;

    $self->pushDebug( 
        $TESTING ? 9 : 
        defined ($args{debug}) ? $args{debug} : 
        $self->getDebug()
    );

    my $sql = requireArg(\%args, 'sql');
    my $sqlargs = requireArg(\%args, 'sqlargs');

    my @caller = caller(1);
    my $cname= $caller[3]; $cname =~ s/.*:://;

    # TEST MODE: don't really do anything.
    $self->mutter("*** TEST MODE *** DOING NOTHING ***") if ($TESTING);

    $self->mutter("$cname(): $sql");
    $self->mutter("$cname(): " . join(", ", @$sqlargs));

    if (! $TESTING) 
    {
        #### DO IT.
    	my $dbh = $self->getHandle();

       	my $sth = $dbh->prepare($sql);
        if ($sth && $sth->execute(@$sqlargs))
        {
	        $sth->finish();	
        } else {
	        $self->setError("A database error has occurred.", fatal => 1, 
                privmsg => "error in sql : $sql\nsql args: " . join(",", @$sqlargs)
            );
        } 
    }
 
    $self->mutter("*** TEST MODE *** DOING NOTHING ***") if ($TESTING);

    $self->popDebug();
	return 0;
}

sub getFromSequence
{
	my ($self, $seqname, %args) = @_;

	my $dbh = $self->getHandle();

    my $sth = $dbh->prepare("select nextval(?) as seqvalue");
    my $rv = 0;

    eval {
        if ($sth && $sth->execute($seqname))
        {
            if (my $r = $sth->fetchrow_hashref())         
		    {
                $rv = $r->{seqvalue};
                $self->mutter("sequence: got '$rv' from $seqname");
		    } 
            $sth->finish();         
        } else {
            die($dbh->errstr || "sth or sth-execute returned false");
        } 
    };
    if ($@ || ($rv<1))
    {
		$self->abort("could not get from database sequence '$seqname': " . 
            ($@ || $dbh->errstr)
        );
    }
    
	return $rv;
}

sub quotedList
{
	my ($self, $listref) = @_;
	my $rv;

	foreach my $val (@$listref)
	{
		$rv .= ', ' if ($rv);
		$val =~ s/'/\\'/g;
		$rv .= "'$val'";
	} 
	return $rv;
}

sub extractIDList # ($array-of-hashes, $idfield, [merge => 1] ) # return ($listref)
# For an array of hashes, extract one value from each (identified by $idfield)
# and put in return list.  
{
	my ($self, $inputs, $keyfield, %args) = @_;

	my @rv;
	my %seen;
	foreach my $item (@$inputs)
	{
		my $val = $item->{$keyfield};
		$val = '' if ($val eq undef);
		if ( $seen{$val} && $args{merge} )
		{
			# skip it.
		} else {
			push (@rv, $val);
			++$seen{$val};
		}
	} 
	return \@rv;
}

sub getPlaceholdersForList
# given a list of N elements, return a string with N '?'s and commas between.
{
	my ($self, $list) = @_;

	return 0 if ($#$list<0);
	my $rv = ('?,' x $#$list) . '?';
	return $rv;
} 

sub substitutePlaceholders # (sql => .., args => $listref, [lookfor => '/LIST/'])
# given a list of N elements and a SQL statement, put sufficient '?'s into the
# statement where /LIST/ (or $args{lookfor}) appears.
{
	my ($self, %args) = @_;

	Baldrick::Util::requireArgs(\%args, [ qw(sql sqlargs) ] );
	
	my $sql = $args{sql};
	my $parmlist = $args{sqlargs};
	my $lookfor = $args{lookfor} || '/LIST/';

	my $rv = $sql;
	if ($rv !~ m#$lookfor#)
	{
		$self->abort("could not insert positional parameters into sql because it had no '$lookfor'. sql: $sql");
	} 

	my $placeholders = $self->getPlaceholdersForList($parmlist);
	$rv =~ s#$lookfor#$placeholders#;
	if ($rv =~ m#$lookfor#)
	{
		$self->abort("positional parameter substitution failed: '$lookfor' still there. sql: $rv");
	} 
	return $rv;
}

sub buildWhere
# IN:
#   where => text
#   wherelist => 
#   keyfield => 'fieldname'
#   keyvalue => value found in keyfield.
#   data => { } -- pull keyvalue from here if needed
#   update => { } -- pull keyvalue from here if needed
# return hash of { wherelist => [ expr, expr ], whereargs => [ expr, expr ] }
{
    my ($self, %args) = @_;

    my $data = defined($args{data}) ? $args{data} :
               defined($args{update}) ? $args{update} : { };

    my @wherelist;
    my @whereargs;

    if (my $wl = $args{wherelist})
    {
        push(@wherelist, @$wl) if (ref($wl));
    }

	if (my $kf = _denasty($args{keyfield})) 
	{
        my $keyvalue = defined($args{keyvalue}) ? $args{keyvalue} :
            defined ($data->{$kf}) ? $data->{$kf} : 
            $self->abort("buildWhere(): keyfield $kf specified but no keyvalue given",  
                uplevel => 2);
        $kf = _denasty($kf);

        push (@wherelist, "$kf=?");
        push (@whereargs, $keyvalue);
    }

    if (my $w = $args{where})
    {
        $w =~ s/^where\s+//ig;
        push (@wherelist, $w);     
    }

    if (my $wa = $args{whereargs})
    {
        push(@whereargs, @$wa) if (ref($wa));
    } 
   
    if ($args{required} && ($#wherelist < 0 ))
    {
        $self->abort("WHERE expression not constructed properly: 
            need where, wherelist, keyfield...", uplevel => 1);
    } 

    my $joiner = $args{conjunction} || 'AND';
    my $rv = {
        wherelist => \@wherelist,
        whereargs => \@whereargs,
        whereexpr => join(" $joiner ", @wherelist), 
    };
    return $rv; 
}

sub _denasty    # strip chars that might be used in sql injection attacks
{
    my ($x) = @_;
    return $x if (!defined($x));

    $x =~ s/[';\\\0]+//g;
    return $x;
}

sub _denastyIdentifier   # strip chars that might be used in sql injection attacks
{
    my ($x) = @_;

    die("An identifier name is required here",
        uplevel => 1) if (!defined($x) || !$x);

    $x =~ s/[';\\\0]+//g;
	$x =~ s/[^a-z0-9_]//ig;

    return $x;
}
1;
