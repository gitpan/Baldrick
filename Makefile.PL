
use ExtUtils::MakeMaker qw(WriteMakefile prompt);
use Data::Dumper;

my $depend = {
    'CGI' => 0,
    'Carp' => 0,
    'Config::General' => 0,
    'Data::Dumper' => 0,
    'DBI' => 0,
    'Time::HiRes' => 0,
    'Getopt::Long' => 0,
    'MIME::Base64' => 0,
    'Test::Simple' => 0.44,
};


#########################################################################

exit(main());

sub main
{
    my $locations = { };

    printBanner();

    print "Please choose one of the following:\n\n";

    print qq#  system: install system-wide, into the Perl interpreter's 'lib'.\n#;
    print qq#\n#;
    print qq#  private: install a private copy of Baldrick - typically into\n#;
    print qq#           a web server's 'cgi-bin' directory.\n\n#;
    print qq#     ("private" is recommended so web sites can be self-contained,\n#;
    print qq#       and multiple sites on the server can have separate Baldrick versions.)\n#;
    print "\n";

    my $itype = readOption("select an installation type:", [ qw(private system) ]);
    print "\n";

    my %dirs = (
    );

    if ($itype eq 'private')
    {
        print qq#The installation directory is typically your web server's "cgi-bin"\n#;
        print qq#directory, or some subdirectory within it; but you can choose any\n#;
        print qq#location you like.\n\n#;

        print qq#In the directory you choose, this installer will create:\n#;
        print qq#   lib -- for Perl libraries (Baldrick)\n#;
        print qq#   etc -- for configuration files\n#;
        print qq#   baldrick-stub -- the loader\n#;

        print qq#Where is your CGI-BIN directory, or other directory to install to?\n\n#;

        $dirs{base} = selectBaseDirectory();
        $dirs{base} =~ s#/$##;  # no trail slash

        $dirs{scripts} = $dirs{base};

        $locations->{PREFIX} = $dirs{base};     # top dir.
        $locations->{INST_SCRIPT} = 'scripts';  # copy from 
        $locations->{INSTALLSCRIPT}    = "$dirs{base}";
        $locations->{INSTALLSITESCRIPT}    = "$dirs{base}";
        $locations->{INSTALLSITELIB}    = "$dirs{base}/lib";
        $locations->{INSTALLSITEARCH}   = "$dirs{base}/lib";
        $locations->{INSTALLMAN1DIR}    = 'none';
        $locations->{INSTALLMAN3DIR}    = 'none';
    
        print qq#\n\n#;
    } else {
        # print qq#Install baldrick-stub loader and example config files?#
        # $dirs{scripts} = $dirs{base};
    } 

    print "Checking for template systems - you should have at least one.\n";
    lookForOneModule( [ qw(Template Text::Template) ] );

    WriteMakefile(
        NAME         => 'Baldrick',
        VERSION_FROM => 'lib/Baldrick/Baldrick.pm',
        AUTHOR       => 'Matt Hucke (hucke@cynico.net)',
        ABSTRACT     => 'web application framework',
        PREREQ_PM    => $depend, 
        %$locations
    );
   
    print "\n\n";
    print qq#Now you're ready to do 'make install'.\n#;
    return 0;
}

sub selectBaseDirectory
{
    my ($self) = @_;

    my @candidates;
    
    if (my $h = $ENV{HOME})
    { 
        if (($h ne '/') && ($h ne '/root'))
        {
            push (@candidates, "$h/cgi-bin/");
        } 
    }

    
    foreach my $d ("/usr/local/apache", "/usr/local/apache2", "/var/www", "/www", 
        "/tmp", "C:/temp", "C:/", "C:/inetpub/wwwroot", "D:/inetpub/wwwroot")
    {
        push (@candidates, "$d/cgi-bin/") if ( (-d $d) && (-w $d) );
    } 
    push (@candidates, "/var/www/example.com/cgi-bin");

    print qq#Suggested installation directories:\n\n#;
    for (my $i=0; $i<=$#candidates; $i++)
    {
        print qq#\t$candidates[$i]\n#;
    } 
    print qq#\n#;

    for (my $i=0; $i<=$#candidates; $i++)
    {
        my $dir = prompt("Base installation directory:", $candidates[$i]);
        if ($dir)
        {
            if ( ($dir eq "/") || ($dir eq "/etc") || ($dir eq "") )
            {
                print "Cowardly refusing to install into '$dir'.\n\n";
                next;
            } 

            return $dir if ( (-d $dir) && (-w $dir));
            mkdir($dir);
            return $dir if ( (-d $dir) && (-w $dir));
            print "Directory '$dir' does not exist or is not writeable, sorry.\n";
        } 
    } 
    die("Too many attempts to answer the question.");
}

sub printBanner
{
    print "************************************************************\n";
    print "\n";
    print "     Baldrick Application Framework\n";
    print "\n";
    print "************************************************************\n";
}

sub readOption
{
    my ($prompt, $list) = @_;

    my $def = $list->[0];
    for (my $i=0; $i<5; $i++)
    {
        my $res = prompt($prompt, $def);
        if ($res)
        {
            foreach my $word (@$list)
            {
                return $res if ($res eq $word);
            } 
        } 
        print "-- please enter one of: " . join(" ", @$list) . "\n\n";
    } 

    die("Too many failed attempts to answer the question.");
}

sub lookForOneModule
{
    my ($list) = @_;

    my @outlist;

    foreach my $mod (@$list)
    {
        if (isInstalled($mod))
        {
            printf "%20s .. OK\n", $mod;
            push (@outlist, $mod);
        } else {
            printf "%20s .. NOT INSTALLED\n", $mod;
        }
    }
    if ($#outlist >=0 )
    {
        return \@outlist;
    } else {
        print ("WARNING: You must first install at least one of these modules:\n\t" . 
            join ("\t", @$list));
        print ("(continuing anyway...)\n");
        return 0;
    }
}



sub isInstalled
{
    my ($mod) = @_;

    eval "use $mod;";
    if ($@)
    {
#        print "error - $@\n";
        return 0;
    } 
    return 1;
}

