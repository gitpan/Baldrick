package Baldrick::SpecialTurnip;

# a SpecialTurnip is an object that represents a database row with a
# unique primary key.

# REQUIREMENTS FOR DESCENDANT CLASSES:
# - the constructor must set up no fields that are
# not present in the database row or in _tableinfo or _metainfo, or
# do anything significant.  This is because the factoryLoad method 
# bypasses constructors and creates these objects from existing hashes
# returned from Database->query().  Anything that isn't loaded from
# the database should be done in analyse().

use strict;

use Baldrick::Turnip;
use Baldrick::Util;
use FileHandle;

our @ISA = qw(Baldrick::Turnip);

sub init    
# tableinfo => {                                                    # REQUIRED.
#   TABLE-NAME => {
#       fieldmap => { 
#           FIELD-NAME => VALIDATION-RULE...
#       }
#       primarykey => [ key list ]
#   # OPTIONAL:
#       pksequence_KEYNAME => sequence name 
#       readonly => 0 | 1   -- cause _handleEditForTable to skip it.
#   }
# }
# metainfo => { # All of these are optional.
#   loadquery => 'select * from table inner join table2 on (..)'...   
#   main_table => tablename,    # used for some quickie ops that don't need joins
#   TABLENAME_readonly => 0 | 1 # another way of doing readonly.
# }
# 
{
    my ($self, %args) = @_;

    if ($args{tableinfo})
    {
        delete $self->{_tablenames};
        delete $self->{_tableinfo};
    } 

    $self->SUPER::init(%args,
        copyRequired => [ qw(tableinfo) ], 
        overwrite => 1, 
        copyDefaults => { 
            config => {},       # hash-tree of config values
            validator => 0,     # Baldrick::InputValidator object (default: create when needed)
            tablenames => 0,    # listref of table names in a specific order
            metainfo => {},     # miscellaneous settings.
            editorName => "", 
        } 
    );

    $self->mutter("init " . ref($self) . ", tables=" . join(", ", @{ $self->getTableNames() } ));
    $self->getTableNames(); # This creates the _tablenames member.
    $self->resetUpdate();   # init _update _changecount etc.

    # Now load 'data' if provided.
    if (my $dat = $args{data})
    {
        my $la = $args{load_args} || {};
	    $self->loadFrom($dat, %$la);
        $self->analyse();
    } 

    # changelog => full-path, changelogdir => dir
    if (my $cfn = $self->_determineChangeLogFilename(%args))
    {
        $self->openChangeLog(changelog => $cfn);
    } 
	return $self;
}

sub finish
{
    my ($self) = @_;
    if (my $ch = $self->{_changelog})
    {
        $ch->close() unless ( $self->{_changeLogNotMine} );
        delete ($self->{_changelog});
    } 
    return 0;
}

sub setEditorName
{
    my ($self, $ename) = @_;
    $self->{_editorName} = $ename;
}

sub getEditorName
{
    my ($self) = @_;
    return $self->{_editorName};
}

sub setEditErrors
{
    my ($self, $ehash) = @_;
    $self->{_editerrors} =$ehash;
    return $self->{_editerrors}; 
}

sub getEditErrors
{
    my ($self) = @_;
    $self->{_editerrors} ||= {};
    return $self->{_editerrors}; 
}

sub getEditErrorCount
{
    my ($self) = @_;
    my $ee = $self->getEditErrors();
    my @enames = keys %$ee;
    return 1+$#enames;
}

sub openChangeLog
# ( changelog => full-path, changelogdir => dir, changelogsuffix => "log", changelogfilename => basename)
{
    my ($self, %args) = @_;

    my $fn = $self->_determineChangeLogFilename(%args) || return 0;

    if (my $h = new FileHandle($fn, "a"))
    {
        $self->{_changelog}  = $h;
        $self->{_changelogFile}  = $fn;
    } else {
        $self->setError("cannot write changelog '$fn': $!");
    } 
}

sub setChangeLogFilename
{
    my ($self, $fn, %args) = @_;

    return ($self->{_changelogFile} = $fn);
}

sub setChangeLogHandle
{
    my ($self, $handle) = @_;

    $self->{_changelog} = $handle;
    $self->{_changeLogNotMine} = 1;
}

sub getChangeLog 
{
    my ($self) = @_;
    return $self->{_changelog};
}

sub getChangeLogFilename
{
    my ($self) = @_;
    return $self->{_changelogFile};
}

sub _determineChangeLogFilename    
# ( changelog => full-path, changelogdir => dir, changelogsuffix => "log", changelogfilename => basename)
{
    my ($self, %args) = @_;
    if (my $fn = $args{changelog})
    {
        return $fn;
    } 

    if (my $dir = $args{changelogdir})
    {
        my $fn= $args{changelogfilename};
        if (!$fn)
        {
            my $pkl = $self->getPrimaryKeyValues(0);
            if ($pkl && $#$pkl>=0)
            {
                $fn = join(".", @$pkl);
                $fn =~ s#[^a-zA-Z0-9_]+#_#g;
            } 
        } 

        my $sfx = $args{changelogsuffix} || 'log';
        my $pfx = $args{changelogprefix} || '';

        if ($fn)
        {
            return sprintf("%s/%s%s.%s", $dir, $pfx, $fn, $sfx);
        } 
    } 
    return '';
}

sub checkInitOK
{
    my ($self) = @_;

    return 1 if ($self->{_tableinfo});
    $self->init( %{ $self->getInitArgs() } );  # hopefully descendant class does setup here.

    return 1 if ($self->{_tableinfo});

    $self->abort("SpecialTurnip " . ref($self) . " lacks tableinfo member");
    return $self;
}

sub getInitArgs     # STATIC.
# Descendant classes should override with something that returns { tableinfo => {} }
{
    my $junk = {};
    return $junk;
}

sub getUpdate       { return $_[0]->{_update} }
sub getFancyUpdate  { return $_[0]->{_fancyupdate} }


sub getFreshestValue    # ($fn) return value from update or self.
{
    my ($self, $fn, %args) = @_;

    my $up = $self->getUpdate() || {};
    if (defined ($up->{$fn}))
    {
        return $up->{$fn};
    } 
    return $self->{$fn};
}

sub getChangeCount
{
    my ($self) = @_;

    my $update = $self->getUpdate() || {};
    my @ukeys = keys %$update;

    $self->{_changecount}   = 1+ $#ukeys;
    return $self->{_changecount};
}

sub getValidator    # Get or create Baldrick::InputValidator object
{
    my ($self) = @_;
    return ($self->{_validator} ||= 
        new Baldrick::InputValidator(creator => $self, sourceValues => $self)
    );
}

sub getMetaInfo # ( [keyname] )
# Get from the 'metainfo' optional init param as a hashref,
# or get one named value from within.
{
    my ($self, $key) = @_;

    my $mi = $self->{_metainfo} || {};

    return $mi->{$key} if ($key);
    return $mi;
}

sub _makeLoadQuery
{
    my ($self) = @_;

    my $tables = $self->getTableNames();
    my $lq = sprintf("SELECT * FROM %s",  $tables->[0]);

    return $lq if ($#$tables == 0);
  
    # No query specified?  Try to make one by joining on primary keys.
    my %pkseen;
    foreach my $table (@$tables)
    {
        my $pklist = $self->getPrimaryKeys(table => $table);
        foreach my $pk (@$pklist)
        {
            next if ($pkseen{$pk});
        
            for (my $jj=0; $jj<=$#$tables; $jj++)
            {
                my $tab2 = $tables->[$jj];
                next if ($tab2 eq $table);

                my $otherpklist = $self->getPrimaryKeys(table => $tables->[$jj]);
                foreach my $pk2 (@$otherpklist)
                {
                    if ($pk2 eq $pk)
                    {
                        $lq .= " inner join $tab2 on ($table.$pk = $tab2.$pk)";
                    } 
                } 
            } 
            $pkseen{$pk} = 1;
        } 
    }
    return $lq;
}

sub getLoadQuery
{
    my ($self) = @_;
    return ($self->getMetaInfo()->{loadquery} ||= $self->_makeLoadQuery());
}

sub getTableNames # (create and) return _tablenames listref.
{
    my ($self) = @_;

    my $tinfo = $self->getTableInfo(0);
    if (! $self->{_tablenames})
    {
        my @tn = sort (keys (%$tinfo));
        $self->{_tablenames} = \@tn;
    } 
    # webprint("getTableNames will return " . join(", ", @{ $self->{_tablenames} }));
    return $self->{_tablenames};
}

sub getTableInfo # ( $tablename || 0, softfail => 0|1  ) 
# return table info for one table or all if tablename=0
{
    my ($self, $tablename, %args) = @_;

    $self->checkInitOK();

    my $tinfo = $self->{_tableinfo};
    if ($tablename)
    {
        my $rv = $tinfo->{$tablename};
        return ($rv) if ($rv);

        return 0 if ($args{softfail});

        $self->fatalError("Table '$tablename' not defined in tableinfo");
    } 
    return $tinfo;
}

sub getFieldMap # (table => TABLE-NAME) or (combined => 1) return HASHREF
{
    my ($self, %args) = @_;
    
    if ($args{combined}) 
    {
        my %allFieldMap = ();
        my $tn = $self->getTableNames();

        foreach my $tab (@$tn)
        {
            my $tinfo = $self->getTableInfo($tab);
            my $fmap = $tinfo->{fieldmap} || next;
            foreach my $field (keys %$fmap)
            {
                $allFieldMap{ $field } = $fmap->{$field};
            } 
        } 
        return \%allFieldMap;
    } elsif (my $tab = requireArg(\%args, 'table') ) {
        my $tinfo = $self->getTableInfo($tab);
        return $tinfo->{fieldmap} || {};
    } 
    ## NOTREACHED.
}

sub getFieldList    # ( (table=> tablename) || (combined => 1) ) return LISTREF
# table => name
# combined => 0|1
# implied_ok => take from source
{ 
    my ($self, %args) = @_;

    my $fm = $self->getFieldMap(%args);
    return [ keys (%$fm) ];
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


sub equals  # ($other, %opts-as-for-compareTo) return 1 or 0.
# convenience wrapper for compareTo
{
    my ($self, $other, %args) = @_;

    return (0 == $self->compareTo($other, %args));
}

sub compareTo   # ($other, %opts) return -1, 0, 1
# Compare two specialturnips based on only those fields that are explicitly mapped.
# ignore => listref -- ignore these fields
# fieldlist => listref -- look at only these fields (else use internal getFieldList()
# transform => transform-expression -- apply transforms to each field value (leave originals unchanged)
{
    my ($self, $other, %args) = @_;

    my $fl = $args{fieldlist} || $self->getFieldList(combined => 1);

    my %ignore;
    if (my $ifields = $args{ignore})
    {
        map { $ignore{$_}=1 } @$ifields;
    } 

    foreach my $k (@$fl)
    {
        # next if ($k =~ m/^_/);
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

    return 0;   # EQUAL!
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

    my $mappedFields = $self->getFieldList( combined => 1 );
    # Get list of fields to copy - construct it from inputs if not found.
    my @fieldlist;

    if (defined ($args{fieldlist}))
    {
        my $fl = $args{fieldlist};
        if (ref($fl))
        {
            @fieldlist = @$fl;
        } elsif ($fl eq 'all') {
            @fieldlist = @$mappedFields;
        } elsif ($fl eq 'source') {
            @fieldlist = grep { $_ !~ m/^_/ } (keys (%$source));
        } elsif ($fl eq '*') {
            @fieldlist = grep { $_ !~ m/^_/ } (keys (%$source));
            push (@fieldlist, @$mappedFields);
        } 
    }
    
    @fieldlist = @$mappedFields if ($#fieldlist < 0);
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

    return $self->analyse() unless ($args{no_analyse});
}

sub getPrimaryKeys  # (table => name | combined => 1, full => 0|1) return listref.
{
    my ($self, %args) = @_;

    my @rv;

    if (my $t = $args{table})
    {
        my $raw = $self->getTableInfo($t)->{primarykey};
        if ($args{full})    # fully qualified
        {
            foreach my $pk (@$raw)
            {
                push (@rv, "$t.$pk");
            } 
        } else {
            return $raw;
        } 
    } elsif ($args{combined}) {
        my $tlist = $self->getTableNames();
        foreach my $table (@$tlist)
        {
            my $junk = $self->getPrimaryKeys(%args, table => $table, combined => 0);
            push (@rv, @$junk);
        } 
    } else {
        $self->fatalError("getPrimaryKeys() needs table or combined arguments");
    } 

    return \@rv;
}


sub getPrimaryKeyValues # ( [$table] ) return LISTREF of my primary key values.
# if table name specified, return primary key values for that table alone;
# else return a list of all primary key values in order.
{
    my ($self, $t) = @_;

    my $tlist  = $t ? [ $t ] : $self->getTableNames();

    my %seen;
    my @out;

    foreach my $table (@$tlist)
    {
        my $pklist = $self->getPrimaryKeys(table => $table);
        foreach my $pk (@$pklist)
        {
            next if ($seen{$pk});
            $seen{$pk} = 1;
            push (@out, $self->{$pk});
        }
    } 
    return \@out;
}

sub checkPrimaryKeys # ()
# For each primary key list in the tableinfo, ensure that $self->{ that-primary-key } is defined.
{
    my ($self) = @_;

    my $tlist  = $self->getTableNames();
    foreach my $table (@$tlist)
    { 
        my $pklist = $self->getPrimaryKeys(table => $table);
        foreach my $pk (@$pklist)
        {
            if (!defined($self->{$pk}))
            {
webdump($self);
                $self->fatalError(ref($self) . ": primary key $pk (table $table) is undefined");
            }
        } 
    }
    return 0;
}

sub assembleWherePK    # (table => TABLE-NAME
# Assemble WHERE from primary key list.
# return { wherelist => .., whereargs => .. , whereconjunction => 'AND' }
{
    my ($self, %args) = @_;

    my @wherelist;
    my @whereargs;

    my $table = requireArg(\%args, 'table');

    my $pklist = $self->getPrimaryKeys(table => $table);
    foreach my $pk (@$pklist)
	{
	    $self->fatalError(ref($self) . "::assembleWherePK() - primary key $table.$pk has no value")
            unless (defined ($self->{$pk}));
	
	    push (@wherelist, "$pk=?");
        push (@whereargs, $self->{$pk} );
    } 

    # Not allowed to have a null where list.
    if ($#wherelist < 0)
    {
        $self->setError(ref($self) . 
            "::assembleWherePK() - empty WHERE list not allowed; no PKs?",
            fatal => $args{softfail} ? 0 : 1);
        return 0;
    } 

    return ( {
        wherelist => \@wherelist,
        whereargs => \@whereargs,
        conjunction => 'AND'
    } );
}    


sub getUniqueKey # ()
# Get a string that makes this SpecialTurnip unique amongst all similar 
# specialturnips; this is good for hashing.
{
    my ($self) = @_;

    my $pkvalues = $self->getPrimaryKeyValues(0);   # 0=all-keys-all-tables.

    my $rv = join('|', @$pkvalues);
    # webprint ("turnip key is '$rv'");
    return $rv;
}

sub _preprocessEditInputs # (inputs => .., [ checkboxes => LIST ] )
# Called by handleEdit() to fix inputs.
{
    my ($self, %args) = @_;

	my $inputs =  requireArg(\%args, 'inputs');

	# convert any undefs to zero for checkbox fields.
	if (my $cblist = $args{checkboxes})
	{
		foreach my $cb (@$cblist)
		{
			next if (defined ( $inputs->{$cb} ) );
			$inputs->{$cb} = 0;
		} 
	} 
    return $inputs;
}

sub resetUpdate
# reset the areas where uncommitted changes are stored.  Called by init(), and by saveChanges()
{
    my ($self) = @_;
    $self->{_changecount}   = 0;
	$self->{_update}        = { }; 
	$self->{_fancyupdate}   = { };
	$self->{_editerrors}   = { };
    return 0;
}


sub handleEdit # (ifnputs => ..., [fieldlist => ...], ...) return changecount
# Examine a hash of inputs (probably from CGI), compare to internal
# fields, and save any changes in $self->{_update} and $self->{_fancyUpdate}.
# args:
#	inputs => user inputs, probably from CGI (REQUIRED) 
# 	input_pfx, input_sfx: pfx/sfx for fieldnames in input.
#	checkboxes => list of fields to treat as checkboxes (setting 0 if absent)
#   fieldlist => update ONLY these fields, otherwise any field in object can be changed.
#   no_overwrite => 0 | 1 -- only update those fields what are empty.
#   autosave => 0 | 1 -- if try, save to database and apply immediately.
#   database => $db -- required only if autosave>0
#   validate => 0 | 1 -- apply validation rules in fieldmap to inputs.
#   flagfields => [ fieldname, fieldname...] 
#   flagprefix_FIELDNAME => how to find flags in input; these are munged into one field
#   limit_tables => [ list ] -- if defined, save to ONLY these tables.
{
	my ($self, %args) = @_;

    # $self->setDebug(9);
    # Fix checkbox arguments.
    $self->_preprocessEditInputs(%args);

    # limit_tables - if it's a listref, only allow edits on tables in the list.
    #   if undef or 0 or anything else, edit all tables.
    my $limitTables = (defined $args{limit_tables} && ref($args{limit_tables})) ? 
        $args{limit_tables} : 0;

	my $changes = 0;
    my $tables = $self->getTableNames();
    foreach my $table (@$tables)
    {
        # if limitTables, update only those tables.
        if ($limitTables)
        {
            next unless grep { $_ eq $table } @$limitTables;
        } 
        $changes += $self->_handleEditForTable(table => $table, %args);
    }

    if ($changes)
    {
        $self->{_changecount} += $changes;
    	if ($args{autosave})
    	{
            # Send just a few args, we don't want anything weird happening.
            my %saveArgs;
            map { $saveArgs{$_} = $args{$_} if (defined $args{$_}) } 
                qw(database test debug); 
    		$self->saveChanges(%saveArgs);
    	}
    }
	return $changes;
}

sub isReadOnly  # ($tablename, [ TABLENAME_readonly => 0|1 ], ...
#    [ignore_table => tablename ], [ignore_tables => LIST ] )
# Return true if this table has been defined as readonly either through
# tableinfo, metainfo, or various parameters that may be sent to this function.
{
    my ($self, $table, %args) = @_;

    my $tinfo = $self->getTableInfo($table);
    return 1 if ($tinfo->{readonly});

    return 1 if ($self->getMetaInfo("${table}_readonly"));
   
    return 1 if ($table eq $args{ignore_table});    # ignore_table => tablename

    if (my $ilist = $args{ignore_tables})           # ignore_tables => [ table, table...] 
    {
        return 1 if (grep { $_ eq $table } @$ilist); 
    } 

    return 0; 
}

sub _handleEditForTable  # (table => .., inputs => .., ..) return changecount.
{
    my ($self, %args) = @_;

	my $table  =  requireArg(\%args, 'table');
	my $inputs =  requireArg(\%args, 'inputs');

    my $tinfo = $self->getTableInfo($table);
    my $flagmap = $tinfo->{flagfields} || {};

    # Don't meddle with tables declared 'readonly'
    return 0 if ($self->isReadOnly($table, %args));

    my %actionPlan;
    if (my $ifields = $args{ignore})
    {
        map { $actionPlan{$_}='ignore' } @$ifields;
    } 
    
    my $fieldlist = $args{fieldlist} || 
        $self->getFieldList(table => $table) || 
        [ keys %$self ];

    my $fieldmap = $self->getFieldMap(table => $table);

    $self->mutter("looking to update table $table, fieldlist=" .
            join(", ", @$fieldlist) );

    my $pfx = $args{input_pfx} || "";
    my $sfx = $args{input_sfx} || "";

    my $val = $self->getValidator();

    my @changedFields; # simple list of fieldnames changed. 
    foreach my $fn (@$fieldlist)
    {
	    next if ($fn =~ m/^_/); # skip private fields.
        next if ($actionPlan{$fn} eq 'ignore');

		my $oldval = $self->{$fn};

	    my $inkey = $pfx . $fn . $sfx;
		my $newval = $inputs->{$inkey};

        if (my $flaginfo = $flagmap->{$fn})
        {
            if (! $newval)  #  FLAGFIELD => ... overrides if present.
            {
                next if ($args{no_flags});
                my $flagpfx = $flaginfo->{prefix};
                $newval = '';
                foreach my $k (sort keys %$inputs)
                {
                    next if (! $inputs->{$k});
                    if ($k =~ m/$pfx$flagpfx(.*)$sfx/)
                    {   
                        $newval .= $flaginfo->{delimiter} . $1;
                    } 
                } 
            }
        } else {
    		next if (!defined $inputs->{$inkey});
        } 


        next if ($args{no_overwrite} && $oldval); # skip fields that have value already.

		$newval =~ s/\0.*//;	# kluge for duplicate fields in CGI input 

        # if force=>1 present, always update, even if same values. 
        next if ( ($newval eq $oldval) && (! $args{force}) );
    
        # Validate the supplied new value if requested.
        if ($args{validate})
        {
            if (my $rule = $fieldmap->{$fn})
            {
                my $err = $val->validateField($fn, value => $newval,
                    rules => $rule
                );
                if ($err)
                {   
                    $self->getEditErrors()->{$fn} = $err;
                    next;   # Do no more with this field.
                }
            } 
        } 

        $self->storeChangeInfo($fn, $newval, oldvalue => $oldval, table => $table);
        push (@changedFields, $fn);
    }

    if ($#changedFields >=0)
    {
        $self->mutter("table $table - stored changes to fields: " . join(', ', @changedFields));
    } else {
        $self->mutter("table $table - no changes stored.");
        return 0;
	} 
    
    return (1+$#changedFields);
}

sub storeChangeInfo # (fieldname, new-value, table => .., [ oldvalue => ...] )
{
    my ($self, $fn, $newval, %args) = @_;

    $self->{_update}->{$fn} = $newval;

	$self->{_fancyupdate}->{$fn} = {
		fieldname => $fn,
		oldvalue => defined($args{oldval}) ? $args{oldval} : $self->{$fn}, 
		newvalue => $newval,
        table => $args{table}
	};
    return $self->{_fancyupdate}->{$fn};
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

sub formatLogPrefix
{
	my ($self, %args) = @_;

    my $pfx = easyfulltime(); 
    my $what = $args{what} || $self->getUniqueKey();
    $pfx .= " [$what]";

    my $who = $args{who} || $self->getEditorName();
	$pfx .= " [$who]" if ($who);

    return $pfx;
}

sub formatLogLines  # ( [ what => 'object description' ] , [ who => 'editor' ] ) return LISTREF
# Format lines for writing to a changelog file.  
{
	my ($self, %args) = @_;

	my $update = $self->getFancyUpdate();

    my $pfx = $self->formatLogPrefix(%args);
	
	my @rv;
	foreach my $k (sort keys %$update)
	{
		my $entry = $update->{$k};

		my $line = $pfx;
		$line .= " $k: '$entry->{oldvalue}' to '$entry->{newvalue}'";
		push (@rv, $line);
	} 
	return \@rv;
}

sub createRecord    # (database => .., [ data => {}||$self ], )
# Create a record in the database for a new object.
# no_apply => don't apply changes first.
{
    my ($self, %args) = @_;

    # Won't create unless all primary keys for all tables are defined in $self.
    $self->checkPrimaryKeys();

    # if 'data' arg is present, use it as the basis for the new record - ignoring $self.
    # otherwise, use $self (after applying changes).
    my $data = 0;
    if ($args{data})
    {
        $data = $args{data};
    } else {
        $self->{_New} = 1;  # set flag to indicate this is a newly-created record.
        if (my $up = $args{update} || $self->{_update})
        {
            $self->applyChanges($up, %args) unless ($args{no_apply});
        }
        $data = $self;
    } 

	my $db =  requireArg(\%args, 'database');

    # Creating a new record.  Copy everything that's in both fieldlist and _update to a 
    # temporary hash (so we don't pass bad fields to insert())!
    my $tlist = $self->getTableNames();
    foreach my $table (@$tlist)
    {
        my $tinfo = $self->getTableInfo($table);
        next if ($self->isReadOnly($table, %args));

        my $fl = $self->getFieldList(table => $table);

        my %record;
        foreach my $k (@$fl)
        {
            if (defined ($data->{$k}))
            { 
                $record{$k} = $data->{$k};
            } else {
                # not an error - if undef, just don't put this in the record, and hope
                # the database table supplies a reasonable default (or is happy with null)
            } 
        }

        $self->mutter("creating a new record in table $table, pkeys=" . 
            join(",", @{ $self->getPrimaryKeyValues($table) } )
        );

        $db->insert(data=>\%record, table => $table, debug => $self->getDebug(),
            test => $args{test});
    } # end foreach table.

    $self->{_Saved} = $self->{_New};  # set flag to indicate this is a newly-created record.
    return $self;
}

sub deleteRecord # (database => .., [limit_table => tablename])
{
	my ($self, %args) = @_;

    $self->checkPrimaryKeys();

    my $db = requireArg(\%args, 'database');

    my $tlist = $self->getTableNames();
    foreach my $table (@$tlist)
    {
        my $tinfo = $self->getTableInfo($table);
        return 0 if ($self->isReadOnly($table, %args));
        if (my $lim = $args{limit_table})
        {
            next if ($table ne $lim);
        } 

        my $where = $self->assembleWherePK(table => $table);
        if (!$where || (0>$#{ $where->{wherelist }} ))
        {
	        $self->fatalError("cannot build WHERE expression to update " . ref($self));
        }
        $db->deleteRows(table => $table, %$where);
    }
}

sub saveChanges # ( database=>.. , ...) return change count.
# apply changes saved earlier via handleEdit().
# opts:
# creating= 0 | 1           -- create a new record instead of doing an update.
# update = {field=>value }  -- if present, use instead of $self->{_update}
# no_apply => 0 | 1
# no_reset => 0 | 1
{
	my ($self, %args) = @_;
    
    $self->checkPrimaryKeys();

    if ($args{creating})    # deprecated, for compatibility.
    {
        $self->createRecord(%args);
        return 1;
    }

    # $update holds the changes to be saved.
    my $update  = $args{update} || $self->requireMember('_update');

    # See if there's anything in _update
 	my @upkeys = keys (%$update);
   	if ($#upkeys < 0)
   	{
   		$self->writeLog("saveChanges called with nothing to do\n", notice => 1);
   	    return 0;
   	} 

	my $db =  requireArg(\%args, 'database');
    my $tlist = $self->getTableNames();
    foreach my $table (@$tlist)
    {
        my $tinfo = $self->getTableInfo($table);

        # never create records in a table marked readonly; we assume these are just
        # something that our main record is JOIN'd to, and it is possibly used in 
        # many places.
        next if ($self->isReadOnly($table, %args));

        my $fl = $self->getFieldList(table => $table);

        my $where = $self->assembleWherePK(table => $table);
        if (!$where || (0>$#{ $where->{wherelist }} ))
        {
	        $self->fatalError("cannot build WHERE expression to update " . ref($self));
        }

        # assemble field list.
        my $fl = $self->getFieldList(table => $table) || next;
            
        my %tempUpdate;
        foreach my $fn (@$fl)
        {
            if (defined ($update->{$fn}))
            {
                $tempUpdate{$fn} = $update->{$fn};
            } 
        }

        if (%tempUpdate)
        {
            $self->mutter("table $table, fields " . join(" ", keys %tempUpdate)); 
        } else {
            $self->mutter("table $table, nothing to update");
            next;   # next table
        }

        $db->update(update => \%tempUpdate, table => $table, %$where,
             debug => $args{debug} || $self->getDebug(), test => $args{test} 
        );
    }
   
    $self->writeUpdateToChangeLog(%args) unless ($args{no_log});
    return ($args{no_apply} ? 1 : $self->applyChanges($update, %args));
}

sub writeUpdateToChangeLog
{
    my ($self, %args) = @_;
    
    if (my $ch = $self->getChangeLog())
    {
        my $loglines = $self->formatLogLines(%args);
        $self->writeChangeLog($loglines);
    } 
    return 0;
}

sub writeChangeLog  # ($lines, [add_prefix => 0|1], [who => 0|1])
{
    my ($self, $loglines, %args) = @_;
  
    if (! ref($loglines) )
    {
        $loglines = [ $loglines ]; 
    } 
 
    if (my $ch = $self->getChangeLog())
    {
        my $pfx = $args{prefix} || ($args{add_prefix} ? $self->formatLogPrefix(%args) : "");
        $pfx .= ' ';

        foreach my $line (@$loglines)
        {
            $ch->print($pfx . $line . "\n");
        } 
    } 
    return 0;
}

sub applyChanges # (\%update, [no_reset => 0|1]) 	return update count.
# Apply a set of arbitrary changes to this object.
# (usually invoked with $s->{_update})
{
	my ($self, $update, %args) = @_;

	$update ||= $self->getUpdate();

	my $count=0;
	foreach my $k (keys %$update)
	{
		if ($self->{$k} ne $update->{$k})
		{
			++$count;
			$self->{$k} = $update->{$k};
		}
	}
	$self->{_MODIFIED} ||= $count;

    $self->resetUpdate() unless ($args{no_reset});

	return $count;
}

sub validateContents
# current => 0|1 -- look at current values as well as update.
# fix => 0|1 -- passed to InputValidator.validateField(); will allow validator to 
#   automatically fix some broken values - such as truncating overlong stuff.
# data => use this as _update
#
# Errors are stored in $self->{_editerrors}
{
    my ($self, %args) = @_;

    my $update = $args{data} || $self->getUpdate();
   
    my $val = $self->getValidator();

    if ($args{current})
    {
        $val->setSource($self);
    } elsif ($update) {
        $val->setSource($update);
    } 

    my $eCount=0;
    my $tlist = $self->getTableNames();
    foreach my $table (@$tlist)
    {
        my $fieldmap = $self->getFieldMap(table => $table);
        foreach my $fn (keys %$fieldmap)
        {
            if (my $rule = $fieldmap->{$fn})
            {
                my $err = $val->validateField($fn, rules => $rule);
                if ($err)
                {   
                    $self->{_editerrors}->{$fn} = $err;
                    $eCount++;
                }
            } 
        } # next field
    } # next table
    return $eCount;
}


sub cloneRecord
{
	my ($self, %args) = @_;

    $self->fatalError("cloneRecord is deprecated in Baldrick 0.84+, please use cloneObject and createRecord instead");
}

############## STATICS ##########################

sub getModelObject  # STATIC
{
    my (%args) = @_;

    if (my $model = $args{model})
    {
        $model->checkInitOK();
        return $model;
    }

    my $classname = requireArg(\%args, 'classname');
    my $model = createObject($classname);
    $model->checkInitOK();

    return $model;
}

sub factoryLoadAll
{
    my (%args) = @_;

    return factoryLoad(wherelist => [ "1=1" ], whereargs => [], %args);
}

sub factoryLoad # (%opts) STATIC
# required:
#   database => ..
# required, one of:
#   classname => SpecialTurnip class
#   model => SpecialTurnip object
# required, one of:
# 	wherelist => [ ] and whereargs => [ ] 
# 	idlist => LISTREF -- will load those that match this primary key.
#   id_in_table => look for ID in PK of this table.
# optional 
#	arg orderby => orderby for sql.
{
	my (%args) = @_;

    my $model   = getModelObject(%args);  # model || classname

    my $db      = requireArg(\%args, 'database');
    my $tables = $model->getTableNames();

	my @whereList = ();
    my @whereArgs = ();

    if (my $wl = $args{wherelist})
    {
        push (@whereList, @$wl);
    }

    if (my $wa = $args{whereargs})
    {
        push (@whereArgs, @$wa);
    } 

	if (my $idlist = $args{idlist}) 
    {
        my $table = $args{id_in_table} || $tables->[0];       # Select first table in table list.
        my $pklist = $model->getPrimaryKeys(table => $table);    

        if ($#$pklist!=0)
        {
            return $model->fatalError("cannot use 'idlist' parameter to factoryLoad when first table has multiple primary keys");
        } 

        push (@whereList, sprintf("%s.%s in (%s)", 
            $table, $pklist->[0], $db->getPlaceholdersForList($idlist))
        );
        push ( @whereArgs, @$idlist);
    }

    # Support explicit where=expression.
	if (my $wtemp = $args{where})
	{
        $wtemp =~ s/^where\s*//i;
        push (@whereList, $wtemp);
	} 

    if ($#whereList < 0)
    {
        $model->abort("SpecialTurnip::factoryLoad() called with no WHERE or IDLIST");
	} 

    # FIX ME: won't work when turnip comes from joined table 
	my $sql = $args{basequery} || $model->getLoadQuery();

    if (! $args{orderby})
    {
        my $allpk = $model->getPrimaryKeys(combined => 1, full => 1);
        $args{orderby} = join(",", @$allpk);
    }

    $sql .= sprintf(" WHERE %s ORDER BY %s",
        join(" and ", @whereList),
        $args{orderby} 
    );
    

	my $resultList = $db->query(sql=>$sql, sqlargs => \@whereArgs,
        resultclass =>  ref($model),
        resultinit => $args{resultinit} || [ $model->getInitArgs() ],
        resultanalyse => []
    );

    if ($args{onerecord})
    {
        return (($resultList && $resultList->[0]) ? $resultList->[0] : 0);
    } 
	return $resultList;
}


1;
