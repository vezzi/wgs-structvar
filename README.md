# Whole Genome Sequencing Structural Variation Pipeline

## Quick start

### Install nextflow

```bash
curl -fsSL get.nextflow.io | bash
mv ./nextflow ~/bin
```

### Run the pipeline

```bash
nextflow run NBISweden/wgs-structvar --project <uppmax_project_id> --bam <bamfile.bam> --run_all
```

This will run both manta and fermikit and create summary files for everything
in the `results` subdirectory.

It is recommended that you set the environment variable `NXF_WORK` to something like

```bash
export NXF_WORK=$SNIC_NOBACKUP/work
```

Preferably in your `.bashrc`.

## General information

This is a pipeline for running the two structural variation callers fermikit
and manta on UPPMAX.

You can choose to run either of the two structural variation callers or both
(and generate summary files).

## External links

* [NextFlow website](http://www.nextflow.io)
* [NextFlow gitter chat](https://gitter.im/nextflow-io/nextflow)

[![Stories in Ready](https://badge.waffle.io/NBISweden/wgs-structvar.png?label=ready&title=Ready)](https://waffle.io/NBISweden/wgs-structvar)
