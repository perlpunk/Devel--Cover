# Copyright 2001-2003, Paul Johnson (pjcj@cpan.org)

# This software is free.  It is licensed under the same terms as Perl itself.

# The latest version of this software should be available from my homepage:
# http://www.pjcj.net

package Devel::Cover;

use strict;
use warnings;

our $VERSION = "0.31";

use DynaLoader ();
our @ISA = qw( DynaLoader );

use Devel::Cover::DB  0.31;
use Devel::Cover::Inc 0.31;

use B qw( class ppname main_cv main_start main_root walksymtable OPf_KIDS );
use B::Debug;
use B::Deparse;

use Cwd ();
use Digest::MD5;

BEGIN { eval "use Pod::Coverage 0.06" }  # We'll use this if it is available.

my $Initialised;                         # import() has been called.

my $Dir;                                 # Directory in cover will be gathered.
my $DB      = "cover_db";                # DB name.
my $Merge   = 1;                         # Merge databases.
my $Summary = 1;                         # Output coverage summary.

my @Ignore;                              # Packages to ignore.
my @Inc;                                 # Original @INC to ignore.
my @Select;                              # Packages to select.
my @Ignore_re;                           # Packages to ignore.
my @Inc_re;                              # Original @INC to ignore.
my @Select_re;                           # Packages to select.

my $Pod     = $INC{"Pod/Coverage.pm"};   # Do pod coverage.
my %Pod;                                 # Pod coverage data.

my @Cvs;                                 # All the Cvs we want to cover.
my $Cv;                                  # Cv we are looking in.
my $Sub_name;                            # Name of the current subroutine.
                                         # Reset when covered.

my $Coverage;                            # Raw coverage data.
my $Cover;                               # Coverage data.

my %Criteria;                            # Names of coverage criteria.
my %Coverage;                            # Coverage criteria to collect.

use vars '$File',                        # Last filename we saw.  (localised)
         '$Line',                        # Last line number we saw.  (localised)
         '$Collect',                     # Whether or not we are collecting
                                         # coverage data.  We make two passes
                                         # over conditions.  (localised)
         '%Files',                       # Whether we are interested in files.
                                         # Used in runops function.
         '$Silent';                      # Output nothing. Can be used anywhere.

($File, $Line, $Collect) = ("", 0, 1);

BEGIN { @Inc = @Devel::Cover::Inc::Inc }
# BEGIN { $^P = 0x004 | 0x010 | 0x100 | 0x200 }
BEGIN { $^P = 0x004 | 0x100 | 0x200 }
# BEGIN { $^P = 0x004 | 0x100 }

{

no warnings "void";  # Avoid "Too late to run CHECK block" warning.

CHECK
{
    return unless $Initialised;

    check_files();

    # reset_op_seq(main_root);
    # reset_op_seq($_->ROOT) for @Cvs;

    set_coverage(keys %Coverage);
    my @coverage = get_coverage();
    %Coverage = map { $_ => 1 } @coverage;

    delete $Coverage{path};  # not done yet
    my $nopod = "";
    if (!$Pod && exists $Coverage{pod})
    {
        delete $Coverage{pod};  # Pod::Coverage unavailable
        $nopod = <<EOM;
Pod coverage is unvailable.  Please install Pod::Coverage from CPAN.
EOM
    }

    set_coverage(keys %Coverage);
    @coverage = get_coverage();
    my $last = pop @coverage;

    print STDOUT __PACKAGE__, " $VERSION: Collecting coverage data for ",
          join(", ", @coverage),
          @coverage ? " and " : "",
          "$last.\n",
          $nopod,
          "Selecting packages matching:", join("\n    ", "", @Select), "\n",
          "Ignoring packages matching:",  join("\n    ", "", @Ignore), "\n",
          "Ignoring packages in:",        join("\n    ", "", @Inc),    "\n"
        unless $Silent;
}

}

END { report() if $Initialised }

sub import
{
    my $class = shift;

    # print __PACKAGE__, ": Parsing options from [@_]\n";

    my $blib = -d "blib";
    @Inc = () if "@_" =~ /-inc /;
    while (@_)
    {
        local $_ = shift;
        /^-silent/   && do { $Silent  = shift; next };
        /^-dir/      && do { $Dir     = shift; next };
        /^-db/       && do { $DB      = shift; next };
        /^-merge/    && do { $Merge   = shift; next };
        /^-summary/  && do { $Summary = shift; next };
        /^-blib/     && do { $blib    = shift; next };
        /^-coverage/ &&
            do { $Coverage{+shift} = 1 while @_ && $_[0] !~ /^[-+]/; next };
        /^-ignore/   &&
            do { push @Ignore,   shift while @_ && $_[0] !~ /^[-+]/; next };
        /^[-+]inc/   &&
            do { push @Inc,      shift while @_ && $_[0] !~ /^[-+]/; next };
        /^-select/   &&
            do { push @Select,   shift while @_ && $_[0] !~ /^[-+]/; next };
        warn __PACKAGE__ . ": Unknown option $_ ignored\n";
    }

    if (defined $Dir)
    {
        chdir $Dir or die __PACKAGE__ . ": Can't chdir $Dir: $!\n";
    }
    else
    {
        $Dir = Cwd::getcwd()
    }

    mkdir $DB unless -d $DB;  # Nasty hack to keep 5.6.1 happy.
    $DB = Cwd::abs_path($DB);

    if ($blib)
    {
        eval "use blib";
        push @Ignore, "\\bt/";
    }

    my $ci = $^O eq "MSWin32";
    @Select_re = map qr/$_/,                           @Select;
    @Ignore_re = map qr/$_/,                           @Ignore;
    @Inc_re    = map $ci ? qr/^\Q$_\//i : qr/^\Q$_\//, @Inc;

    for my $c (Devel::Cover::DB->new->criteria)
    {
        my $func = "coverage_$c";
        no strict "refs";
        $Criteria{$c} = $func->();
    }

    %Coverage = (all => 1) unless keys %Coverage;

    $Initialised = 1;
}

sub cover_names_to_val
{
    my $val = 0;
    for my $c (@_)
    {
        if (exists $Criteria{$c})
        {
            $val |= $Criteria{$c};
        }
        elsif ($c eq "all" || $c eq "none")
        {
            my $func = "coverage_$c";
            no strict "refs";
            $val |= $func->();
        }
        else
        {
            warn __PACKAGE__ . qq(: Unknown coverage criterion "$c" ignored.\n);
        }
    }
    $val;
}

sub set_coverage
{
    set_criteria(cover_names_to_val(@_));
}

sub add_coverage
{
    add_criteria(cover_names_to_val(@_));
}

sub remove_coverage
{
    remove_criteria(cover_names_to_val(@_));
}

sub get_coverage
{
    return unless defined wantarray;
    my @names;
    my $val = get_criteria();
    for my $c (sort keys %Criteria)
    {
        push @names, $c if $val & $Criteria{$c};
    }
    return wantarray ? @names : "@names";
}

my %File_cache;

sub get_location
{
    my ($op) = @_;

    $File = $op->file;
    $Line = $op->line;

    # warn "$File::$Line\n";

    # If there's an eval, get the real filename.  Enabled from $^P & 0x100.

    ($File, $Line) = ($1, $2) if $File =~ /^\(eval \d+\)\[(.*):(\d+)\]/;

    if (exists $File_cache{$File})
    {
        $File = $File_cache{$File};
        return;
    }

    my $file = $File;

    $File =~ s/ \(autosplit into .*\)$//;

    my $f = $File;
    until (-f $f)
    {
        last unless $f =~ s|^\.\./||;
    }

    # my $f = Cwd::abs_path($File);
    $File = $f if defined $f && -f $f;

    $File =~ s/^$Dir\///;
    # $File =~ s/^blib\///;
    # $File =~ s/^lib\///;

    $File_cache{$file} = $File;

    # warn "File: $file => $File\n";
}

sub use_file
{
    my ($file) = @_;

    $file = $1 if $file =~ /^\(eval \d+\)\[(.*):\d+\]/;
    $file =~ s/ \(autosplit into .*\)$//;
    $file =~ s|\.\./\.\./lib/POSIX.pm|$INC{"POSIX.pm"}|e;  # TODO - fix
    # Possibly fixed by merging on MD5 sums.

    my $files = \%Files;
    return $files->{$file} if exists $files->{$file};

    # print STDERR "checking <$file>\n";

    for (@Select_re) { return $files->{$file} = 1 if $file =~ $_ }
    for (@Ignore_re) { return $files->{$file} = 0 if $file =~ $_ }
    for (@Inc_re)    { return $files->{$file} = 0 if $file =~ $_ }

    $files->{$file} = -e $file;
    warn __PACKAGE__ . qq(: Can't find file "$file": ignored.\n)
        unless $files->{$file} || $Silent || $file =~ /\(eval \d+\)/;

    $files->{$file}
}

sub check_file
{
    my ($cv) = @_;

    return unless class($cv) eq "CV";

    my $op = $cv->START;
    return unless $op->can("file") && class($op) ne "NULL" && is_state($op);

    my $file = $op->file;
    my $use  = use_file($file);
    # printf "%6s $file\n", $use ? "use" : "ignore";

    $use
}

sub B::GV::find_cv
{
    my $cv = $_[0]->CV;
    return unless $$cv;

    push @Cvs, $cv if check_file($cv);
    push @Cvs, grep check_file($_), $cv->PADLIST->ARRAY->ARRAY
        if $cv->PADLIST->can("ARRAY") &&
           $cv->PADLIST->ARRAY &&
           $cv->PADLIST->ARRAY->can("ARRAY");
};

sub check_files
{
    # print "Checking files\n";

    @Cvs = grep check_file($_), B::main_cv->PADLIST->ARRAY->ARRAY;

    my %seen_pkg;

    walksymtable(\%main::, "find_cv", sub { !$seen_pkg{$_[0]}++ });

    # print Dumper \%seen_pkg;
    # print Dumper \%Files;
}

sub report
{
    die "Devel::Cover::import() not run: " .
        "did you require instead of use Devel::Cover?\n"
        unless defined $Dir;

    chdir $Dir or die __PACKAGE__ . ": Can't chdir $Dir: $!\n";

    my @collected = get_coverage();
    # print "Collected @collected\n";
    return unless @collected;
    set_coverage("none");

    # print "Processing cover data\n@Inc\n";

    $Coverage = coverage() || die "No coverage data available.\n";

    # use Data::Dumper; print Dumper $Coverage;

    check_files();

    get_cover(main_cv, main_root);
    # print "init, ", Dumper \B::begin_av;
    # print "init array, ", Dumper B::begin_av->ARRAY;
    get_cover($_) for B::begin_av->isa("B::AV") ? B::begin_av->ARRAY : ();
    get_cover($_) for B::check_av->isa("B::AV") ? B::check_av->ARRAY : ();
    get_cover($_) for B::init_av ->isa("B::AV") ? B::init_av ->ARRAY : ();
    get_cover($_) for B::end_av  ->isa("B::AV") ? B::end_av  ->ARRAY : ();
    get_cover($_) for @Cvs;

    for my $file (keys %$Cover)
    {
        my $use = use_file($file);
        # warn sprintf "%-4s using $file\n", $use ? "" : "not";

        unless ($use)
        {
            delete $Cover->{$file};
            next;
        }

        if (open my $fh, "<", $file)
        {
            binmode $fh;
            $Cover->{$file}{meta}{digest} = Digest::MD5->new->addfile($fh)->hexdigest;
        }
        else
        {
            warn __PACKAGE__ . ": Can't open $file for MD5 digest: $!\n";
        }
    }

    my $cover = Devel::Cover::DB->new
    (
        cover     => $Cover,
        collected => [ @collected ],
    );

    my $existing;
    eval
    {
        $existing = Devel::Cover::DB->new(db        => $DB,
                                          collected => [ @collected ])
            if $Merge
    };

    $cover->merge($existing) if $existing;
    $cover->merge_identical_files;
    print STDOUT __PACKAGE__, ": Writing coverage database to $DB\n"
        unless $Silent;
    $cover->write($DB);
    $cover->print_summary if $Summary && !$Silent;
}

sub add_statement_cover
{
    my ($op) = @_;

    get_location($op);
    return unless $File;

    return unless $Collect;

    # print "Statement: ", $op->name, "\n";

    my $key = pack("I*", $$op) . pack("I*", $op->seq);
    push @{$Cover->{$File}{statement}{$Line}},
         [[$Coverage->{statement}{$key} || 0]];
    if ($Sub_name)
    {
        push @{$Cover->{$File}{subroutine}{$Line}},
             [[$Coverage->{statement}{$key} || 0, $Sub_name]];
        # print "$File:$Line:$Sub_name:", $Coverage->{statement}{$key} || 0, "\n";
        $Sub_name = "";
    }
    push @{$Cover->{$File}{time}{$Line}},
         [[$Coverage->{time}{$key}]]
        if exists $Coverage->{time} && exists $Coverage->{time}{$key};
}

sub add_branch_cover
{
    return unless $Collect && $Coverage{branch};

    my ($op, $type, $text, $file, $line) = @_;

    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    my $key = pack("I*", $$op) . pack("I*", $op->seq);
    # print STDERR "Branch cover from $file:$line $type:$text\n";

    my $c = $Coverage->{condition}{$key};
    if ($type eq "and")
    {
        shift @$c;
        $c = [ ($c->[2] || 0), ($c->[0] || 0) + ($c->[1] || 0) ];
    }
    elsif ($type eq "or")
    {
        shift @$c;
        $c = [ ($c->[2] || 0) + ($c->[0] || 0), ($c->[1] || 0) ];
    }
    elsif ($type eq "elsif" && !exists $Coverage->{branch}{$key})
    {
        $c = [ ($c->[1] || 0), ($c->[0] || 0) ];
    }
    else
    {
        $c = $Coverage->{branch}{$key} || [0, 0];
    }

    push @{$Cover->{$file}{branch}{$line}},
         [
             [ map($_ || 0, @$c) ],
             {
                 text  => $text,
             },
         ];
}

my %condition_locations;

sub add_condition_cover
{
    my ($op, $strop, $left, $right) = @_;

    unless ($Collect)
    {
        $condition_locations{$$op} = [ $File, $Line ];
        return
    }

    local ($File, $Line) = @{$condition_locations{$$op}}
        if exists $condition_locations{$$op};

    my $key = pack("I*", $$op) . pack("I*", $op->seq);
    # print STDERR "Condition cover $$op from $File:$Line\n";

    my $type = $op->name;
    $type =~ s/assign$//;

    my $c = $Coverage->{condition}{$key};
    shift @$c;

    my $count;

    if ($type eq "or")
    {
        if ($op->first->sibling->name eq "const")
        {
            $c = [ ($c->[2] || 0), ($c->[0] || 0) + ($c->[1] || 0) ];
            $count = 2;
        }
        else
        {
            @$c = @{$c}[2, 1, 0];
            $count = 3;
        }
    }
    elsif ($type eq "and")
    {
        @$c = @{$c}[2, 0, 1];
        $count = 3;
    }
    elsif ($type eq "xor")
    {
        # !l&&!r  l&&!r  l&&r  !l&&r
        @$c = @{$c}[2, 1, 3, 0];
        $count = 4;
    }
    else
    {
        die qq(Unknown type "$type" for conditional);
    }

    push @{$Cover->{$File}{condition}{$Line}},
         [
             $c,
             {
                 type  => "${type}_${count}",
                 op    => $strop,
                 left  => $left,
                 right => $right,
             },
         ];
}

sub is_scope       { &B::Deparse::is_scope }
sub is_state       { &B::Deparse::is_state }
sub is_ifelse_cont { &B::Deparse::is_ifelse_cont }

{

no warnings "redefine";

my $original_deparse;
BEGIN { $original_deparse = \&B::Deparse::deparse }

sub B::Deparse::deparse
{
    my $self = shift;
    my ($op, $cx) = @_;

    my $class = class($op);
    my $null  = $class eq "NULL";

    my $name = $op->can("name") ? $op->name : "Unknown";

    # print "Deparse <$name>\n";

    if ($Collect)
    {
        # Get the coverage on this op.

        if ($class eq "COP" && $Coverage{statement})
        {
            add_statement_cover($op);
        }
        elsif (!$null && $name eq "null"
                      && ppname($op->targ) eq "pp_nextstate"
                      && $Coverage{statement})
        {
            # If the current op is null, but it was nextstate, we can still
            # get at the file and line number, but we need to get dirty.

            bless $op, "B::COP";
            add_statement_cover($op);
            bless $op, "B::$class";
        }
        elsif ($name eq "cond_expr")
        {
            local ($File, $Line) = ($File, $Line);
            my $cond  = $op->first;
            my $true  = $cond->sibling;
            my $false = $true->sibling;
            if (!($cx < 1 && (is_scope($true) && $true->name ne "null") &&
                    (is_scope($false) || is_ifelse_cont($false))
                    && $self->{'expand'} < 7))
            {
                my ($file, $line) = ($File, $Line);
                { local $Collect; $cond = $self->deparse($cond, 8) }
                add_branch_cover($op, "if", "$cond ? :", $file, $line);
            }
            else
            {
                my ($file, $line) = ($File, $Line);
                { local $Collect; $cond = $self->deparse($cond, 1) }
                add_branch_cover($op, "if", "if ($cond) { }", $file, $line);
                while (class($false) ne "NULL" && is_ifelse_cont($false))
                {
                    my $newop   = $false->first;
                    my $newcond = $newop->first;
                    my $newtrue = $newcond->sibling;
                    # last in chain is OP_AND => no else
                    $false = $newtrue->sibling;
                    my ($file, $line);
                    {
                        # local ($File, $Line);
                        # get_location($newcond);
                        ($file, $line) = ($File, $Line);
                    }
                    { local $Collect; $newcond = $self->deparse($newcond, 1) }
                    add_branch_cover($newop, "elsif", "elsif ($newcond) { }",
                                     $file, $line);
                }
            }
        }
    }

    my $d = eval { $original_deparse->($self, @_) };
    $@ ? "Deparse error: $@" : $d
}

sub B::Deparse::logop
{
    my $self = shift;
    my ($op, $cx, $lowop, $lowprec, $highop, $highprec, $blockname) = @_;
    my $left  = $op->first;
    my $right = $op->first->sibling;
    my ($file, $line) = ($File, $Line);
    if ($cx < 1 && is_scope($right) && $blockname && $self->{expand} < 7)
    {
        # if ($a) {$b}
        $left  = $self->deparse($left, 1);
        $right = $self->deparse($right, 0);
        add_branch_cover($op, $lowop, "$blockname ($left)", $file, $line);
        return "$blockname ($left) {\n\t$right\n\b}\cK"
    }
    elsif ($cx < 1 && $blockname && !$self->{parens} && $self->{expand} < 7)
    {
        # $b if $a
        $right = $self->deparse($right, 1);
        $left  = $self->deparse($left, 1);
        add_branch_cover($op, $lowop, "$blockname $left", $file, $line);
        return "$right $blockname $left"
    }
    elsif ($cx > $lowprec && $highop)
    {
        # $a && $b
        $left  = $self->deparse_binop_left($op, $left, $highprec);
        $right = $self->deparse_binop_right($op, $right, $highprec);
        add_condition_cover($op, $highop, $left, $right);
        return $self->maybe_parens("$left $highop $right", $cx, $highprec)
    }
    else
    {
        # $a and $b
        $left  = $self->deparse_binop_left($op, $left, $lowprec);
        $right = $self->deparse_binop_right($op, $right, $lowprec);
        add_condition_cover($op, $lowop, $left, $right);
        return $self->maybe_parens("$left $lowop $right", $cx, $lowprec)
    }
}

sub B::Deparse::logassignop
{
    my $self = shift;
    my ($op, $cx, $opname) = @_;
    my $left = $op->first;
    my $right = $op->first->sibling->first;  # skip sassign
    $left = $self->deparse($left, 7);
    $right = $self->deparse($right, 7);
    add_condition_cover($op, $opname, $left, $right);
    return $self->maybe_parens("$left $opname $right", $cx, 7);
}

}

sub get_cover
{
    my $deparse = B::Deparse->new("-l");

    my $cv = $deparse->{curcv} = shift;
    my $gv = $cv->GV;
    $Sub_name = $cv->GV->SAFENAME unless ($gv->isa("B::SPECIAL"));

    # print "getting cover for $Sub_name\n";

    if ($Pod && $Coverage{pod})
    {
        unless ($gv->isa("B::SPECIAL"))
        {
            my $stash = $gv->STASH;
            my $pkg   = $stash->NAME;
            my $file  = $cv->FILE;
            if ($Pod{$file} ||= Pod::Coverage->new(package => $pkg))
            {
                get_location($cv->START);
                my $covered;
                for ($Pod{$file}->covered)
                {
                    $covered = 1, last if $_ eq $Sub_name;
                }
                unless ($covered)
                {
                    for ($Pod{$file}->uncovered)
                    {
                        $covered = 0, last if $_ eq $Sub_name;
                    }
                }
                push @{$Cover->{$File}{pod}{$Line}[0]}, $covered if defined $covered;
            }
        }
    }

    @_ ? $deparse->deparse(shift, 0) : $deparse->deparse_sub($cv, 0)
}

sub get_cover_x
{
    my $cv = shift;
    printf "get_cover_x %p\n", $cv;
    print "cv - $cv - ", Dumper $cv;
    print ">>>";
    print get_cover($cv);
    print "<<<\n";
}

bootstrap Devel::Cover $VERSION;

1

__END__

=head1 NAME

Devel::Cover - Code coverage metrics for Perl

=head1 SYNOPSIS

 perl -MDevel::Cover yourprog args
 cover

 perl -MDevel::Cover=-db,cover_db,-coverage,statement,time yourprog args

 To test an uninstalled module:

 cover -delete
 HARNESS_PERL_SWITCHES=-MDevel::Cover make test
 cover

 If the module does not use the t/*.t framework:

 PERL5OPT=-MDevel::Cover make test

=head1 DESCRIPTION

This module provides code coverage metrics for Perl.

If you can't guess by the version number this is an alpha release.

Code coverage data are collected using a pluggable runops function which
counts how many times each op is executed.  These data are then mapped
back to reality using the B compiler modules.  There is also a statement
profiling facility which needs a better backend to be really useful.

The B<cover> program can be used to generate coverage reports.

Statement, branch, condition, subroutine, pod and time coverage information is
reported.  Statement coverage data should be reasonable, although there may be
some statements which are not reported.  Branch and condition coverage data
should be mostly accurate too, although not always what one might initially
expect.  Subroutine coverage should be as accurate as statement coverage.  Pod
coverage comes from Pod::Coverage.  Coverage data for path coverage are not yet
collected.

The B<gcov2perl> program can be used to convert gcov files to
Devel::Cover databases.

You may find that the results don't match your expectations.  I would
imagine that at least one of them is wrong.

THe most appropriate mailing list on which to discuss this module would
be perl-qa.  Discussion has migrated there from perl-qa-metrics which is
now defunct.  http://lists.perl.org/showlist.cgi?name=perl-qa

Requirements:

  Perl 5.6.1 or greater.  (Perl 5.7.0 is also unsupported.)
  The ability to compile XS extensions.
  Storable (in the core in Perl 5.8.0 and above).
  Digest::MD5 (in the core in Perl 5.8.0 and above).
  Pod::Coverage if you want pod coverage.
  Template Toolkit 2 if you want HTML output.

=head1 OPTIONS

 -blib               - "use blib" and ignore files matching \bt/ (default true
                       iff blib directory exists).
 -coverage criterion - Turn on coverage for the specified criterion.  Criteria
                       include statement, branch, path, subroutine, pod, time,
                       all and none (default all available).
 -db cover_db        - Store results in coverage db (default ./cover_db).
 -dir path           - Directory in which coverage will be collected (default
                       cwd).
 -ignore RE          - Ignore files matching RE.
 -inc path           - Set prefixes of files to ignore (default @INC).
 +inc path           - Append to prefixes of files to ignore.
 -merge val          - Merge databases, for multiple test benches (default on).
 -select RE          - Only report on files matching RE.
 -summary val        - Print summary information iff val is true (default on).

=head1 ACKNOWLEDGEMENTS

Some code and ideas cribbed from:

 Devel::OpProf
 B::Concise
 B::Deparse

=head1 SEE ALSO

 Devel::Cover::Tutorial
 B
 Pod::Coverage

=head1 BUGS

Did I mention that this is alpha code?

See the BUGS file.

=head1 VERSION

Version 0.31 - 22nd December 2003

=head1 LICENCE

Copyright 2001-2003, Paul Johnson (pjcj@cpan.org)

This software is free.  It is licensed under the same terms as Perl itself.

The latest version of this software should be available from my homepage:
http://www.pjcj.net

=cut