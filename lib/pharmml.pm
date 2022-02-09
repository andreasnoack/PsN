package pharmml;

use strict;
use warnings;
use File::Spec::Functions qw(devnull);
use PsN;
use nonmemrun;
use MouseX::Params::Validate;

sub is_pharmml
{
    my $filename = shift;

    open my $fh, '<', $filename;
    my $line = <$fh>;
    if ($line =~ /^\<\?xml/) {    # Magic xml descriptor.
        seek $fh, 0, 0;
        while ($line = <$fh>) {            # Check if file contains start of PharmML element
            if ($line =~ /\<PharmML/) {
                close $fh;
                return 1;
            }
        }
    }

    close $fh;
    return 0;
}

sub is_java_installed
{
    if (system('java -version >' . devnull . ' 2>&1') == 0) {
        return 1;
    } else {
        return 0;
    }
}

sub _get_classpath
{
    my $classpath = $PsN::config->{'_'}->{'converter_path'};

    return $classpath;
}

sub convert_file
{
    my $filename = shift;
    my $classpath = _get_classpath;

    my $rc = system("java -cp \"$classpath/*\" eu.ddmore.convertertoolbox.cli.Main -in $filename -out . -sn PharmML -sv 0.3.0 -tn NMTRAN -tv 7.2.0");

    return $rc;
}

sub check_converted_model
{
    my $filename = shift;
    my $ok;

    # Run nmtran to test converted file before using it with PsN

    my $ref = nonmemrun::setup_paths(nm_version => $PsN::nm_version);
    my $command = $ref->{'full_path_nmtran'} . "<$filename";

    system($command);
    unlink('FCON', 'FSIZES', 'FSTREAM', 'prsizes.f90', 'FSUBS', 'FSUBS2', 'FSUBS.f90');
    unlink('FSUBS_MU.F90', 'FLIB', 'LINK.LNK', 'FWARN', 'trash.tmp');
    if (not -e 'FREPORT') {
        $ok = 0;
    } else {
        $ok = 1
    }

    unlink('FDATA', 'FREPORT');
    return $ok;
}

sub create_minimal_pharmml
{
    # Create a minimal PharmML from a NONMEM model.
    # The intent is to use it in conjunction with an SO to
    # automatically extract types of variability parameters for example
    # This is admittedly a quick hack using neither a PharmML library nor an xml library to generate xml.
    my %parm = validated_hash(\@_,
        model => { isa => 'model' },
        filename => { isa => 'Str' },
    );
    my $model = $parm{'model'};
    my $filename = $parm{'filename'};

    eval { require so::xml; };
    if ($@) {
        die "Unable to find libxml2\n";
    }

    open my $fh, '>', $filename;

    print $fh <<'END';
<?xml version="1.0" encoding="UTF-8"?>
<PharmML xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns="http://www.pharmml.org/pharmml/0.8/PharmML"
    xsi:schemaLocation="http://www.pharmml.org/pharmml/0.8/PharmML"
    xmlns:math="http://www.pharmml.org/pharmml/0.8/Maths"
    xmlns:ct="http://www.pharmml.org/pharmml/0.8/CommonTypes"
    xmlns:ds="http://www.pharmml.org/pharmml/0.8/Dataset"
    xmlns:mdef="http://www.pharmml.org/pharmml/0.8/ModelDefinition"
    xmlns:mstep="http://www.pharmml.org/pharmml/0.8/ModellingSteps"
    xmlns:design="http://www.pharmml.org/pharmml/0.8/TrialDesign"
    writtenVersion="0.8.1">

    <ct:Name>Minimal model generated by nmoutput2so</ct:Name>
    <ModelDefinition xmlns="http://www.pharmml.org/pharmml/0.8/ModelDefinition">
        <VariabilityModel blkId="vm_err" type="residualError">
            <Level referenceLevel="false" symbId="DV"/>
        </VariabilityModel>
        <VariabilityModel blkId="vm_eta" type="parameterVariability">
            <Level referenceLevel="true" symbId="ID"/>
        </VariabilityModel>
END

    print_parameter_model(file => $fh, model => $model);

    print $fh ' ' x 4, "</ModelDefinition>\n";
    print_trial_design(file => $fh, model => $model);
    print $fh "</PharmML>";

    close $fh;
}

sub print_parameter_model
{
    my %parm = validated_hash(\@_,
        file => { isa => 'Ref' },
        model => { isa => 'model' },
    );
    my $file = $parm{'file'};
    my $model = $parm{'model'};

    print $file <<'END';
        <ParameterModel blkId="pm">
END

    print_population_parameters(file => $file, model => $model);
    print_random_variables(file => $file, model => $model);
    print_correlations(file => $file, model => $model);

print $file <<'END';
        </ParameterModel>
END
}

sub get_name
{
    my $option = shift;
    my $name = $option->label;
    if (not defined $name) {
        $name = $option->coordinate_string;
    }
    if (not so::xml::match_symbol_idtype($name)) {
        $name = so::xml::mangle_symbol_idtype($name);
    }
    return $name;
}

sub print_population_parameters
{
    my %parm = validated_hash(\@_,
        file => { isa => 'Ref' },
        model => { isa => 'model' },
    );
    my $file = $parm{'file'};
    my $model = $parm{'model'};

    for my $record (@{$model->problems->[0]->thetas}, @{$model->problems->[0]->omegas}, @{$model->problems->[0]->sigmas}) {
        for my $option (@{$record->options}) {
            my $name = get_name($option);
            print $file '            <PopulationParameter symbId="' . $name . '"/>' . "\n"; # FIXME if no label and symbol washing
        }
    }
}

sub print_random_variables
{
    my %parm = validated_hash(\@_,
        file => { isa => 'Ref' },
        model => { isa => 'model' },
    );
    my $file = $parm{'file'};
    my $model = $parm{'model'};

    my $n = 1;
    for my $record (@{$model->problems->[0]->omegas}, @{$model->problems->[0]->sigmas}) {
        for my $option (@{$record->options}) {
            if ($option->on_diagonal) {
                my $symbol = get_name($option);
                my $name = "ETA";
                my $var_blkId = "vm_eta";
                my $var_symbId = "ID";
                if ($option->coordinate_string =~ /SIGMA/) {
                    $n = 1;
                    $name = "EPS";
                    $var_blkId = "vm_err";
                    $var_symbId = "DV";
                }
                print $file ' ' x 12, "<RandomVariable symbId=\"$name$n\">\n";
                print $file ' ' x 16, "<ct:VariabilityReference>\n";
                print $file ' ' x 20, "<ct:SymbRef blkIdRef=\"$var_blkId\" symbIdRef=\"$var_symbId\"/>\n";
                print $file ' ' x 16, "</ct:VariabilityReference>\n";
                print $file ' ' x 16, "<Distribution>\n";
                print $file ' ' x 20, "<ProbOnto xmlns=\"http://www.pharmml.org/probonto/ProbOnto\" name=\"Normal2\">\n";   # FIXME: Does not support SD
                print $file ' ' x 24, "<Parameter name=\"mean\">\n";
                print $file ' ' x 28, "<ct:Assign>\n";
                print $file ' ' x 32, "<ct:Real>0</ct:Real>\n";
                print $file ' ' x 28, "</ct:Assign>\n";
                print $file ' ' x 24, "</Parameter>\n";
                print $file ' ' x 24, "<Parameter name=\"var\">\n";
                print $file ' ' x 28, "<ct:Assign>\n";
                print $file ' ' x 32, "<ct:SymbRef symbIdRef=\"$symbol\"/>\n";
                print $file ' ' x 28, "</ct:Assign>\n";
                print $file ' ' x 24, "</Parameter>\n";
                print $file ' ' x 20, "</ProbOnto>\n";
                print $file ' ' x 16, "</Distribution>\n";
                print $file ' ' x 12, "</RandomVariable>\n";
                $n++;
            }
        }
    }
}

sub print_correlations
{
    my %parm = validated_hash(\@_,
        file => { isa => 'Ref' },
        model => { isa => 'model' },
    );
    my $file = $parm{'file'};
    my $model = $parm{'model'};

    my %diag;       # Coordstring to symbol

    for my $record (@{$model->problems->[0]->omegas}, @{$model->problems->[0]->sigmas}) {
        for my $option (@{$record->options}) {
            if ($option->on_diagonal) {
                my $symbol = get_name($option);
                $diag{$option->coordinate_string} = $symbol;
            }
        }
    }

    for my $record (@{$model->problems->[0]->omegas}, @{$model->problems->[0]->sigmas}) {
        for my $option (@{$record->options}) {
            if (not $option->on_diagonal) {
                my $symbol = get_name($option);
                $option->coordinate_string =~ /(\d+),(\d+)/;
                my $first = $1;
                my $second = $2;
                $option->coordinate_string =~ /(\w+)/;
                my $type = $1;
                my $first_diag = "$type($first,$first)";
                my $second_diag = "$type($second,$second)";
                my $first_diag_name = $diag{$first_diag};
                my $second_diag_name = $diag{$second_diag};
                my $var_blkId = "vm_eta";
                my $var_symbId = "ID";
                if ($option->coordinate_string =~ /SIGMA/) {
                    $var_blkId = "vm_err";
                    $var_symbId = "DV";
                }
                print $file ' ' x 12, "<Correlation>\n";
                print $file ' ' x 16, "<ct:VariabilityReference>\n";
                print $file ' ' x 20, "<ct:SymbRef blkIdRef=\"$var_blkId\" symbIdRef=\"$var_symbId\"/>\n";
                print $file ' ' x 16, "</ct:VariabilityReference>\n";
                print $file ' ' x 16, "<Pairwise>\n";
                print $file ' ' x 20, "<RandomVariable1>\n";
                print $file ' ' x 24, "<ct:SymbRef symbIdRef=\"$first_diag_name\"/>\n";
                print $file ' ' x 20, "</RandomVariable1>\n";
                print $file ' ' x 20, "<RandomVariable2>\n";
                print $file ' ' x 24, "<ct:SymbRef symbIdRef=\"$second_diag_name\"/>\n";
                print $file ' ' x 20, "</RandomVariable2>\n";
                print $file ' ' x 20, "<CorrelationCoefficient>\n";
                print $file ' ' x 24, "<ct:Assign>\n";
                print $file ' ' x 28, "<ct:SymbRef symbIdRef=\"$symbol\"/>\n";
                print $file ' ' x 24, "</ct:Assign>\n";
                print $file ' ' x 20, "</CorrelationCoefficient>\n";
                print $file ' ' x 16, "</Pairwise>\n";
                print $file ' ' x 12, "</Correlation>\n";
            }
        }
    }
}

sub print_trial_design
{
    my %parm = validated_hash(\@_,
        file => { isa => 'Ref' },
        model => { isa => 'model' },
    );
    my $file = $parm{'file'};
    my $model = $parm{'model'};

    my $columns = $model->problems->[0]->inputs->[0]->get_nonskipped_columns();
    my $data_file = $model->problems->[0]->datas->[0]->get_absolute_filename();

    print $file ' ' x 4, "<design:TrialDesign>\n";
    print $file ' ' x 8, "<design:ExternalDataSet toolName=\"NONMEM\" oid=\"nm_ds\">\n";
    for my $col (@$columns) {
        print $file ' ' x 12, "<design:ColumnMapping>\n";
        print $file ' ' x 16, "<ds:ColumnRef columnIdRef=\"$col\"/>\n";
        print $file ' ' x 16, "<ct:SymbRef symbIdRef=\"$col\"/>\n";
        print $file ' ' x 12, "</design:ColumnMapping>\n";
    }
    print $file ' ' x 12, "<DataSet xmlns=\"http://www.pharmml.org/pharmml/0.8/Dataset\">\n";
    print $file ' ' x 16, "<Definition>\n";
    my $num = 1;
    for my $col (@$columns) {
        my $columnType = "undefined";
        $columnType = 'id' if ($col eq 'ID');
        $columnType = 'dv' if ($col eq 'DV');
        print $file ' ' x 20, "<Column columnId=\"$col\" columnType=\"$columnType\" valueType=\"real\" columnNum=\"$num\"/>\n";
        $num++;
    }
    print $file ' ' x 16, "</Definition>\n";
    print $file ' ' x 16, "<ExternalFile oid=\"dataset_id\">\n";
    print $file ' ' x 20, "<path>$data_file</path>\n";
    print $file ' ' x 16, "</ExternalFile>\n";
    print $file ' ' x 12, "</DataSet>\n";
    print $file ' ' x 8, "</design:ExternalDataSet>\n";
    print $file ' ' x 4, "</design:TrialDesign>\n";
}

# Filter out SAME and FIX?

1;
