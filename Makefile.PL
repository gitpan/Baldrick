

use ExtUtils::MakeMaker qw(WriteMakefile prompt);

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME         => 'Baldrick',
    VERSION_FROM => 'lib/Baldrick/Baldrick.pm', # finds \$VERSION
    AUTHOR       => 'Matt Hucke (hucke@cynico.net)',
    ABSTRACT     => 'web application framework',
    PREREQ_PM    => {
                     'CGI' => 0,
                     'Carp' => 0,
                     'Config::General' => 0,
                     'Data::Dumper' => 0,
                     'DBI' => 0,
                     'Time::HiRes' => 0,
                     'Getopt::Long' => 0,
                     'MIME::Base64' => 0,
                     'Test::Simple' => 0.44,
                    },
#    EXE_FILES    => [ "bin/baldrick-stub" ],
);
