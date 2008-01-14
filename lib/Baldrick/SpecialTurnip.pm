package Baldrick::SpecialTurnip;

# a SpecialTurnip is an object that represents a database row with a
# unique primary key.

# REQUIREMENTS FOR DESCENDANT CLASSES:
# - the constructor must set up no fields that are
# not present in the database row or in @requiredInternalFields, or
# do anything significant.  This is because the factoryLoad method 
# bypasses constructors and creates these objects from existing hashes
# returned from Database->query().  Anything that isn't loaded from
# the database should be done in analyse().

use strict;

use Baldrick::Turnip;
use Baldrick::Util;
use Baldrick::TurnipWagon;

our @ISA = qw(Baldrick::Turnip);

our @optionalInternalFields = qw(tablename primarykey pksequence fieldlist config tablemap);

sub init    # tablename => ..,  primarykey => .., ...
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args,
        copyOptional => \@optionalInternalFields,
        copyDefaults => { config => {} }, 
        required => 0
    );

    # Support legacy 'fieldlist' and 'tablename' by converting into 'tablemap'.
    if (! $self->{_tablemap}) 
    {
        if (my $fl = $self->{_fieldlist})
        {
            if (my $tables = $self->getTableNames())
            {
                $self->{_tablemap} = { };
                foreach my $tab (@$tables)
                {
                    my $tm = {};
                    map { $tm->{$_} = '' } @$fl;
                    $self->{_tablemap}->{$tab} = $tm;
                } 
            } 
        } 
    }  ## end of not-tablemap thingy.

    # handleEdit will store changes here.
    $self->{_update} = {};
    $self->{_fancyupdate} = {};
    $self->{_changecount} = 0;

    if (my $dat = $args{data})
    {
        my $la = $args{load_args} || {};
	    $self->loadFrom($dat, %$la);
    } 
	return $self;
}

sub getTableNames # return listref
{
	my ($self) = @_;
	if (my $tm = $self->{_tablemap})
	{
		return [ keys (%$tm) ];
	}
	return [ split(/\|/, $self->{_tablename}) ]; 
}

sub checkInitOK
{
    my ($self) = @_;
    return 1 if ($self->{_primarykey});

    $self->init();
    return 1 if ($self->{_primarykey});

    $self->abort("SpecialTurnip " . ref($self) . " has no primary key.");
    return $self;
}

sub getFieldList 
# table => name
# combined => 0|1
# implied_ok => take from source
{ 
    my ($self, %args) = @_;

    my $map = $self->{_tablemap};

    if (my $tab = $args{table})
    {
        if ($map)
        {
            if (my $thismap = $map->{$tab})
            {
                $self->mutter("GET FIELD LIST $tab: " . 
                    join(", ", keys %$thismap ));
                return [ keys %$thismap ];
            } 
        } else {
            $self->setError("WARNING: getFieldList($tab) without tablemap", warning => 1);
        } 
    } elsif ($args{combined}) {
        if ($map)
        {
            my @rv;
            foreach my $tab (keys %$map)
            {
                my $thismap = $map->{$tab};
                push (@rv, (keys %$thismap));
            }
            return \@rv;
        } else {
            $self->setError("WARNING: getFieldList(combined) without tablemap", warning => 1);
        }
    } 
 
    my $rv = $self->{_fieldlist};
    return $rv if ($rv);

    if ($args{implied_ok})
    {
        return $self->getImpliedFieldList(%args);
    } 
    return 0;
}

sub getImpliedFieldList  # data => ...
# If no explicit fieldlist fs present, construct one by returning 
# keys of data or self.
{
    my ($self, %args) = @_;
    my $source = $args{data} || $self;
    my $pfx = $args{prefix} || '';

    my @junk;
    foreach my $k (keys %$source)
    {
        next if ($k =~ m/^_/);
        if ($pfx && ($k =~ m/^$pfx(.*)/))
        {
            push (@junk, $1);
        } else {
            push (@junk, $k);
        } 
    }
    return \@junk;
} 


sub equals
{
    my ($self, $other, %args) = @_;

    return ( ($self->compareTo($other, %args)  == 0)  ? 1 : 0);
}

sub compareTo   # return -1, 0, 1
{
    my ($self, $other, %args) = @_;

    my $fl = $args{fieldlist} || $self->getFieldList(implied_ok => 1);
    my %ignore;
    if (my $ifields = $args{ignore})
    {
        map { $ignore{$_}=1 } @$ifields;
    } 

    foreach my $k (@$fl)
    {
        next if ($k =~ m/^_/);
        next if ($ignore{$k});

        my $left = $self->{$k};
        my $right = $other->{$k};
        next if ($left eq $right);    # bypass transforms if identical

        if (my $t = $args{transform})
        {
            $left = applyStringTransforms($left, $t);
            $right = applyStringTransforms($right, $t);
        } 

        my $rv = $left cmp $right;
        return $rv if ($rv);
    } 

    return 0;   # EQUALS!
}

sub loadFrom    # ($source, prefix => )
# Load from database row, CGI input stream, etc.
# Use fieldlist as list of fields to import if available.
# args:
#   fieldlist => \@fields   
#   fieldlist => 'all' -- get fieldlist from all tables
#   fieldlist => 'source' 
#   fieldlist => '*' -- all + source
#   prefix => prefix on fieldnames in inputs.
#   no_undef => convert 'undef' to zero.
{
    my ($self, $source, %args) = @_;

    # Get list of fields to copy - construct it from inputs if not found.
    my @fieldlist;

    if (defined ($args{fieldlist}))
    {
        my $fl = $args{fieldlist};
        if (ref($fl))
        {
            @fieldlist = @$fl;
        } elsif ($fl eq 'all') {
            $fl = $self->getFieldList( combined => 1 );
            @fieldlist = @$fl;
        } elsif ($fl eq 'source') {
            @fieldlist = keys (%$source);
        } elsif ($fl eq '*') {
            @fieldlist = keys (%$source);
            $fl = $self->getFieldList( combined => 1 );
            push (@fieldlist, @$fl);
        } 
    }
    
    if ($#fieldlist < 0)
    { 
        my $fl = $self->getFieldList( combined => 1 );
        @fieldlist = @$fl if ($fl);
    } 

    if ($#fieldlist < 0)
    { 
        @fieldlist = keys (%$source);
    } 

    $self->mutter( ref($self) . "::loadFrom(): got field list " . join(", ", @fieldlist) );

    my $pfx = $args{prefix} || '';

    # Now that we have our fieldlist, copy each one.
    foreach my $fn (@fieldlist)
    {
        if (defined ($source->{ $pfx . $fn }))
        {
            $self->{$fn} = $source->{ $pfx . $fn };
        } else {
           $self->{$fn} = $args{no_undef} ? 0 : undef;
        }
    } 

    return $self->analyse();
}

sub getPrimaryKey
{
    my ($s) = @_;
    $s->checkInitOK();
    return $s->{_primarykey};
}

sub splitPrimaryKey
{
    my ($s) = @_;

    my $pkdef = $s->getPrimaryKey() || $s->abort(
        "cannot get unique key for " . ref($s));
    my @rv = split(/\|/, $pkdef);
    return \@rv;
}

sub getPrimaryKeyValues # return LISTREF of my primary key values.
{
    my ($s) = @_;
    my @out;
    my $pklist = $s->splitPrimaryKey();
    for (my $i=0; $i<=$#$pklist; $i++)
    {
        push (@out, $s->{ $pklist->[$i] });
    } 
    return \@out;
}

sub getUniqueKey
{
    my ($s) = @_;
    my $pk = $s->splitPrimaryKey();
    my $rv;
    for (my $i=0; $i<=$#$pk; $i++)
    {
        $rv .= "|" if ($rv>0);
        $rv .= $s->{$pk->[$i]};
    } 

    # print "<li>turnip key is '$rv'</li>\n";

    return $rv;
}


sub handleEdit # (ifnputs => ..., [fieldlist => ...], ...) return changecount
# Examine a hash of inputs (probably from CGI), compare to internal
# fields, and save any changes in $s->{_update}.
#
# args:
#	inputs => user inputs, probably from CGI (REQUIRED) 
# 	input_pfx, input_sfx: pfx/sfx for fieldnames in input.
#	checkboxes => list of fields to treat as checkboxes (setting 0 if absent)
# 	numerics => fieldlist - use == instead of eq for these
#   fieldlist => update ONLY these fields, otherwise any field in object can be changed.
#   no_overwrite => 0 | 1 -- only update those fields what are empty.
#   autosave => 0 | 1 -- if try, save to database and apply immediately.
#   database => $db -- required only if autosave>0
{
	my ($self, %args) = @_;

	my $inputs =  requireArg(\%args, 'inputs');
	my $changes = 0;

	# STASH IT FOR LATER.
	$self->{_update} ||= { }; 
	$self->{_fancyupdate} ||= { };

	# convert any undefs to zero for checkbox fields.
	if ($args{checkboxes})
	{
		foreach my $cb (@{ $args{checkboxes} })
		{
			next if (defined ( $inputs->{$cb} ) );
			$inputs->{$cb} = 0;
		} 
	} 

	my %numerics;
	if ($args{numerics})
	{
		foreach my $fn (@{ $args{numerics} })
		{
			$numerics{$fn}=1;
		} 
	} 

    foreach my $table (@{ $self->getTableNames() })
    {
	    my $fieldlist = $args{fieldlist} || 
            $self->getFieldList(table => $table) || 
            [ keys %$self ];
        $self->mutter("looking to update table $table, fieldlist=" .
            join(", ", @$fieldlist) );

        my @changedFields;  # just for debug!
	    foreach my $fn (@$fieldlist)
	    {
	        next if ($fn =~ m/^_/); # skip private fields.

		    my $inkey = $args{input_pfx} . $fn . $args{input_sfx};
		    next if (!defined $inputs->{$inkey});

		    my $newval = $inputs->{$inkey};
		    my $oldval = $self->{$fn};
            next if ($args{no_overwrite} && $oldval); # skip fields that have value already.

		    $newval =~ s/\0.*//;	# fix for duplicate fields in CGI input 

            if ($args{maxlengths})
			{
				my $max = $args{maxlengths}->{$fn};
				if ($max>0)
				{
					$newval = substr($newval, 0, $max);
				} 
			} 

            if (! $args{force})     # if force=>1 present, always update, even if same values. 
            {
		        next if ($newval eq $oldval);
		        if ($numerics{$fn})
		        {
			        next if ($newval == $oldval);
		        } 
            }
		
		    ++$changes;
            $self->storeChangeInfo($fn, $newval, oldvalue => $oldval,
                table => $table
            );
            push (@changedFields, $fn);
	    } # next field    

        if ($#changedFields >=0)
        {
            $self->mutter("table $table - stored changes to fields: " . join(', ', @changedFields));
        } else {
            $self->mutter("table $table - no changes stored.");
        }
	} # next table / fieldlist

    $self->{_changecount} += $changes;

    if ($changes)
    {
    	if ($args{autosave})
    	{
    		$self->saveChanges(database => requireArg(\%args, 'database') );
    	}
    }
	return $changes;
}

sub storeChangeInfo # (fieldname, new-value, [ oldvalue => ...] )
{
    my ($s, $fn, $newval, %args) = @_;

    $s->{_update}->{$fn} = $newval;

	$s->{_fancyupdate}->{$fn} = {
		fieldname => $fn,
		oldvalue => defined($args{oldval}) ? $args{oldval} : $s->{$fn}, 
		newvalue => $newval,
        table => $args{table}
	};
    return $s->{_fancyupdate}->{$fn};
}

sub getUpdate { return $_[0]->{_update} }

sub getFancyUpdate
# return an update object with a bit more info.
{
	my ($self, %args) = @_;
	return $self->{_fancyupdate};
}

sub getUpdatedValue # $fieldname, [ no_current => 0|1]
# Return value from update, if present.
# else return current value unless no_current
{
    my ($self, $fn, %args) = @_;
   
    my $upd = $self->getUpdate();
    if ($upd && defined($upd->{$fn}))
    {
        return $upd->{$fn};
    }  
    return $self->{$fn} unless ($args{no_current});
    return undef;
}

sub formatLogLines
# args what => ...
# args who => ...	
{
	my ($s, %args) = @_;
	my $fu = $s->{_fancyupdate};
	my $now = Baldrick::Util::easydate() . " " . Baldrick::Util::easytime();
	
	my @rv;
	foreach my $k (sort keys %$fu)
	{
		my $entry = $fu->{$k};

		my $line = $now;
		$line .= " $args{what}" if ($args{what});
		$line .= " $args{who}" if ($args{who});
		$line .= " $k: '$entry->{oldvalue}' => '$entry->{newvalue}'";
		push (@rv, $line);
	} 
	return \@rv;
}

sub createRecord
{
    my ($s, %args) = @_;
    return $s->saveChanges(creating => 1, %args);
}

sub checkPrimaryKeys
{
    my ($self) = @_;
    my $pklist = $self->splitPrimaryKey();
    foreach my $pk (@$pklist)
    {
        if (!defined($self->{$pk}))
        {
            $self->abort(ref($self) . ": primary key $pk is undefined");
        }
    } 
    return 0;
}

sub saveChanges # (database=>foo) return change count.
# apply changes saved earlier via handleEdit().
{
	my ($self, %args) = @_;

	my $db =  requireArg(\%args, 'database');
    $self->checkPrimaryKeys();

	my @tables = split(/\|/, $self->requireMember('_tablename'));
	my $kf  = $self->requireMember('_primarykey');

    if ($args{creating})
    {
        # Creating a new record.  Copy everything that's in both fieldlist and _update to a 
        # temporary hash (so we don't pass bad fields to insert())!
        foreach my $tab (@tables)
        {
            my %record;

            my $up = $args{data} || $self->{_update} || $self;
            my $fl = $args{fieldlist} || $self->getFieldList(table => $tab) 
                || [ keys %$up ];
            $fl = keys (%$self) if ($#$fl<0);

            foreach my $k (@$fl)
            {
                next if ($k =~ m/^_/);

                if (defined ($up->{$k}))
                { 
                    $record{$k} = $up->{$k};
                } elsif (defined ($self->{$k})) {
                    $record{$k} = $self->{$k};
                }
            }

            $self->mutter("creating a new record in table $tab, $kf=" . 
                join(",", @{ $self->getPrimaryKeyValues() } )
            );
            $db->insert(data=>\%record, table => $tab,
                debug => $self->{_debug});
        }
        $self->{_New} = 1;
	    return $self->{_update} ? $self->applyChanges($self->{_update}) : 0;
    } else {
        my $pklist = $self->splitPrimaryKey();
	    my $up  = $args{update} || $self->requireMember('_update');
    
        # See if there's anything in _update
    	my @upkeys = keys (%$up);
    	if ($#upkeys < 0)
    	{
    		$self->writeLog("saveChanges called with nothing to do\n", notice => 1);
    		return -1;
    	} 

        foreach my $table (@tables)
        {
	        # Assemble WHERE from primary key list.
	        my @where;
	        my @where_args;
	        for (my $jj=0; $jj<=$#$pklist; $jj++)
	        {
	            my $k = $pklist->[$jj] || next;
	            next if (! defined ($self->{$k}));
	
	            push (@where, "$k=?");
	            push (@where_args, $self->{$k} );
	        } 
            
            # assemble field list.
            my $fl = $self->getFieldList(table => $table);
            if (!$fl)
            {
                $fl = [ keys %$up ] ;
            } 
            
            my %tempUpdate;
            foreach my $fn (@$fl)
            {
                next if (!defined ($up->{$fn}));
                $tempUpdate{$fn} = $up->{$fn};
            } 
            $self->mutter("table $table, fields " . join(" ", keys %tempUpdate)); 
                next if (! %tempUpdate);

	        if ($#where >=0)
	        {   
                foreach my $kk (keys %tempUpdate)
                {
                    $self->writeLog(sprintf(
                        "update %s (%s): %s=%s",
                        $table, join(', ', @where_args), 
                        $kk, $tempUpdate{$kk}
                    ));
                }

		        $db->update(update => \%tempUpdate, table => $table,
	                wherelist => \@where, whereargs => \@where_args,
	                debug => $self->{_debug}
	            );
	        } else {
	            $self->abort("cannot build WHERE expression to update " . ref($self));
	        } 
        }
	    return $self->applyChanges($up);
    }
}

sub applyChanges # (\%update) 	return update count.
# Apply a set of arbitrary changes to this object.
# (usually invoked with $s->{_update})
{
	my ($s, $up) = @_;
	my $count=0;

	$up ||= $s->{_update};

	foreach my $k (keys %$up)
	{
		if ($s->{$k} ne $up->{$k})
		{
			++$count;
			$s->{$k} = $up->{$k};
		}
	}
	$s->{MODIFIED} ||= $count;
	return $count;
}

sub defaultSort
{
    my ($a, $b) = @_;

    my $fieldlist = $a->splitPrimaryKey();

    return sortByFields($a, $b, $fieldlist);
}

sub sortByFields
{
    my ($a, $b, $fieldlist) = @_;

    foreach my $f (@$fieldlist)
    {
        my $aval = $a->{$f};
        my $bval = $b->{$f};
        # print "<li>CMP $aval / $bval </li>\n";

        return -1 if ($aval < $bval);
        return  1 if ($aval > $bval);
        return -1 if ($aval lt $bval);
        return  1 if ($aval gt $bval);
    }
    return 0;
}

sub cloneRecord
# make a copy of the record in the DB with a new primary key.
# opts:
#	db => database # REQUIRED.
#	newvalues => { field1=>val1, ...} 	# hashref of things to override.
# 	pkvalue => new primary key value
#	pksequence => sequencename # DB sequence to get it from
{
	my ($s, %opts) = @_;

	Baldrick::Util::requireArgs(\%opts, [ qw(db) ] );

	# clone the in-memory object.
	my $clone = { } ;
	%$clone = %$s;
	bless ($clone, ref($s));

# 	Baldrick::Util::dumpObject($clone, listhtml => 1);

	if ($opts{newvalues})
	{
		foreach my $k (keys %{$opts{newvalues}})
		{
			$clone->{$k} = $opts{newvalues}->{$k};
		} 
	} 

	my $db = $opts{db};
	my $table 	= $s->{_tablename};
	my $pk 		= $s->{_primarykey};

	# Now, get a new primary key.
	my $seqname = $opts{pksequence} || $s->{_pksequence};
	if ($opts{primarykey})
	{
		$clone->{$pk} = $opts{pkvalue};
	} elsif ($seqname) { 
		my $newpk = $db->getFromSequence($seqname);
		if ($newpk)
		{
			$clone->{$pk} = $newpk;
		} else {
			$s->setError("cannot sequence new primary key", fatal => 1);
		}
	} else {
		$s->setError("cannot determine new primary key", fatal => 1);
	} 

	$db->insert(table => $table, data => $clone);
	return $clone;
}

sub _staticGetModelFromArgs
{
    my (%args) = @_;

    my $classname;
    my $model = $args{model};
    if ($model)
    {
        $classname = ref($model);
    } else {
        $classname = requireArg(\%args, 'classname');
        $model = dynamicNew($classname);
    }
    $model->init(%{ $model->getInitArgs() });
    return $model;
}

sub factoryLoad # (%opts) STATIC
# Derived classes could override this to provide defaults for args such 
# as 'table'.
# 	arg db 		=> bdk:database REQUIRED
#	arg classname => classname to bless into. REQUIRED
# 	arg tablename => tablename REQUIRED
# one of these is needed:
# 	arg where => sql 'where' part 
# 	arg idlist => LISTREF
# optional 
#	arg orderby => orderby for sql.
{
	my (%args) = @_;

    my $model = _staticGetModelFromArgs(%args);
    my $db = requireArg(\%args, 'database');

	my @whereList = ();
    my @whereArgs = ();

    if ($args{wherelist})
    {
        push ( @whereList, @{ $args{wherelist} } );
        push ( @whereArgs, @{ $args{whereargs} } ) if ($args{whereargs});
    } 

	if (my $list = $args{idlist}) 
    {
        push (@whereList, sprintf("%s in (%s)", 
            $model->getPrimaryKey(), 
            $db->getPlaceholdersForList($list)
        ));
        push ( @whereArgs, @$list);
    }

	if (my $wtemp = $args{where})
	{
        $wtemp =~ s/^where\s*//i;
        push (@whereList, $wtemp);
	} 

    if ($#whereList < 0)
    {
        $model->abort("SpecialTurnip::factoryCreate() called with no WHERE or IDLIST");
	} 

    # FIX ME: won't work when turnip comes from joined table 
	my $sql = sprintf("SELECT * FROM %s WHERE %s ORDER BY %s",
        $model->{_tablename}, 
        join(" and ", @whereList),
        $args{orderby} || $model->getPrimaryKey()
    );
    

	my $resultList = $db->query(sql=>$sql, sqlargs => \@whereArgs,
        resultclass =>  ref($model),
        resultinit => $args{resultinit} || [ $model->getInitArgs() ],
        resultanalyse => []
    );

	return $resultList;
}

sub getInitArgs     # STATIC.
{
    my $junk = {};
    return $junk;
}

sub validateContents
# current => .. -- look at current values as well as update.
# fix => ... -- passed to InputValidator.validateField(); will truncate overlong values.
{
    my ($self, %args) = @_;

    my $tm  = $self->requireMember('_tablemap');
    my $up = $args{data} || $self->{_update};
   
    my $val = new Baldrick::InputValidator(creator => $self);
    $self->{_validator} = $val;

    my $errs = 0;

    foreach my $tablename (keys %$tm)
    {
        my $thismap = $tm->{$tablename};
        foreach my $fn (keys %$thismap)
        {
            my $rule = $thismap->{$fn};
            if ($args{current})
            {
                $val->setSource($self);
            } elsif ($up) {
                $val->setSource($up);
            } 
            my $rc = $val->validateField($fn, rules => $rule, %args);
            $errs++ if ($rc);

        } 
    } 
    return $errs;
}

1;
