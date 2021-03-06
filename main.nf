#!/usr/bin/env nextflow

/*
WGS Structural Variation Pipeline
*/

// 0. Pre-flight checks

if (params.help) {
    usage_message()
    exit 0
}

if (!params.bam) {
    exit 1, 'You need to specify a bam file, see --help for more information'
}

bamfile = file(params.bam)

if (! bamfile.exists()) {
    exit 1, "The bamfile, '$params.bam', does not exist"
}


if (!params.project) {
    exit 1, 'You need to specify what project to run under, see --help for more information'
}

if (params.run_all) {
    params.run_fermikit = true
    params.run_manta = true
}


startup_message()

// 1. Run manta

// Try to guess location of bamindex file. If we can't find it create it
// else put that in the bamfile_index channel.

bamindex = infer_bam_index_from_bam()
if (!bamindex) {
    process index_bamfile {
        input:
            file 'bamfile' from bamfile
        output:
            file 'bamfile.bai' into bamfile_index

        module 'bioinfo-tools'
        module "$params.modules.samtools"

        // We only need one core for this part
        if ( nextflow_running_as_slurmjob() ) {
            executor 'local'
        }
        else {
            executor 'slurm'
            queue 'core'
            time params.short_job
        }

        when: params.run_manta == true

        script:
        """
        samtools index bamfile
        """
    }
}
else {
    // The bamfile file already exists, put it in the channel.
    Channel.fromPath( bamindex ).set { bamfile_index }
}

process run_manta {
    input:
        file 'bamfile_tmp' from bamfile
        file 'bamfile.bai' from bamfile_index
    output:
        file 'manta.bed' into manta_bed

    publishDir params.outdir, mode: 'copy'

    module 'bioinfo-tools'
    module "$params.modules.manta"

    when: params.run_manta == true

    script:
    """
    # Manta follows symlinks and expects the index to be with the original
    # file, so we copy it, and then clean up at script EXIT with a trap.
    # TODO, this is fixed in manta v0.29.5, https://github.com/Illumina/manta/issues/32
    DIR=`pwd`
    function cleanup() {
        echo "CLEAN UP"
        cd \$DIR
        if [ -f bamfile ]; then
            rm bamfile
        fi
    }
    trap cleanup EXIT
    cp bamfile_tmp bamfile

    configManta.py --normalBam bamfile --referenceFasta $params.ref_fasta --runDir testRun
    cd testRun
    ./runWorkflow.py -m local -j $params.threads
    mv results/variants/diploidSV.vcf.gz ../manta.vcf.gz
    cd ..
    gunzip -c manta.vcf.gz > manta.vcf
    SVvcf2bed.pl manta.vcf > manta.bed
    """
}


// 2. Run fermikit

// Try to guess location of fastq file. If we can't find it create it
// else put that in the fastq channel.
if (!params.fastq) {
    params.fastq = infer_fastq_from_bam()
}

if (!params.fastq) {
    process create_fastq {
        input:
            file 'bamfile' from bamfile

        output:
            file 'fastq.fq.gz' into fastq

        module 'bioinfo-tools'
        module "$params.modules.samtools"

        // We only need one core for this part
        if ( nextflow_running_as_slurmjob() ) {
            executor 'local'
        }
        else {
            executor 'slurm'
            queue 'core'
            time params.short_job
        }

        when: params.run_fermikit == true

        script:
        """
        samtools bam2fq bamfile | gzip - > fastq.fq.gz
        """
    }
}
else {
    // The fastq file already exists, put it in the channel.
    Channel.fromPath( params.fastq ).set { fastq }
}

process fermikit_calling {
    input:
        file 'sample.fq.gz' from fastq
    output:
        file 'fermikit.bed' into fermi_bed

    publishDir params.outdir, mode: 'copy'

    module 'bioinfo-tools'
    module "$params.modules.fermikit"
    module "$params.modules.samtools"
    module "$params.modules.vcftools"
    module "$params.modules.tabix"

    when: params.run_fermikit == true

    script:
    """
    fermi2.pl unitig -s$params.genome_size -t$params.threads -l$params.readlen -p sample sample.fq.gz > sample.mak
    make -f sample.mak
    run-calling -t$params.threads $params.ref_fasta sample.mag.gz > calling.sh
    bash calling.sh
    vcf-sort -c sample.sv.vcf.gz > fermikit.vcf
    bgzip -c fermikit.vcf > fermikit.vcf.gz
    SVvcf2bed.pl fermikit.vcf > fermikit.bed
    """
}



// 3. Create summary files
mask_urls = [
    "https://github.com/cc2qe/speedseq/raw/master/annotations/ceph18.b37.lumpy.exclude.2014-01-15.bed",
    "https://github.com/lh3/varcmp/raw/master/scripts/LCR-hs37d5.bed.gz"
]

Channel.from( 0..<mask_urls.size() ).map { [it, mask_urls[it]] }.set { mask_urls_channel }

process download_masks {
    input:
        set val(index), val(mask_url) from mask_urls_channel
    output:
        file 'mask_*.bed.gz' into masks

    // Does not use many resources, run it locally
    executor 'local'

    """
    wget -O mask_${index}.bed.gz $mask_url
    """
}


// Collect both bed files and combine them with the mask files
beds = manta_bed.mix( fermi_bed )
beds.spread( masks.buffer(size: 2) ).set { mask_input }

process mask_beds {
    input:
        set file(bedfile), file(mask1), file(mask2) from mask_input
    output:
        file '*_masked.bed' into masked_beds
        file '*_masked_*.bed'

    publishDir params.outdir, mode: 'copy'

    // Does not use many resources, run it locally
    executor 'local'

    module 'bioinfo-tools'
    module "$params.modules.bedtools"

    """
    BNAME=\$( echo $bedfile | cut -d. -f1 )
    MASK_FILE=\${BNAME}_masked.bed
    cat $bedfile \
        | bedtools intersect -v -a stdin -b $mask1 -f 0.25 \
        | bedtools intersect -v -a stdin -b $mask2 -f 0.25 > \$MASK_FILE


    ## In case grep doesn't find anything it will exit with non-zero exit
    ## status, which will cause slurm to abort the job, we want to continue on
    ## error here.
    set +e

    ## Create filtered bed files
    for WORD in DEL INS DUP; do
        grep -w \$WORD \$MASK_FILE > \${BNAME}_masked_\${WORD,,}.bed
    done

    set -e # Restore exit-settings
    """
}

// To make intersect files we need to combine them into one channel with
// toList(). And also figure out if we have one or two files, therefore the
// tap and count_beds.
masked_beds.tap { count_beds_tmp }.toList().set { intersect_input }
count_beds_tmp.count().set { count_beds }

process intersect_files {
    input:
        set file(bed1), file(bed2) from intersect_input
        val nbeds from count_beds
    output:
        file "combined*.bed"

    publishDir params.outdir, mode: 'copy'

    // Does not use many resources, run it locally
    executor 'local'

    module 'bioinfo-tools'
    module "$params.modules.bedtools"

    when: nbeds == 2

    script:
    """
    ## In case grep doesn't find anything it will exit with non-zero exit
    ## status, which will cause slurm to abort the job, we want to continue on
    ## error here.
    set +e

    ## Create intersected bed files
    for WORD in DEL INS DUP; do
        intersectBed -a <( grep -w \$WORD $bed1 ) -b <( grep -w \$WORD $bed2 ) \
            -f 0.5 -r \
            | sort -k1,1V -k2,2n > combined_masked_\${WORD,,}.bed
    done

    set -e # Restore exit-settings
    """
}

def usage_message() {
    log.info ''
    log.info 'Usage:'
    log.info '    nextflow main.nf --bam <bamfile> [more options]'
    log.info ''
    log.info 'Options:'
    log.info '  Required'
    log.info '    --bam           Input bamfile'
    log.info '    --project       Uppmax project to log cluster time to'
    log.info '  Optional'
    log.info '    --help          Show this message and exit'
    log.info '    --fastq         Input fastqfile (default is bam but with fq as fileending)'
    log.info '    --run_manta     Run manta (default)'
    log.info '    --run_fermikit  Run fermikit'
    log.info '    --run_all       Run all callers'
    log.info '    --long_job      Running time for long job (callers, fermi and manta)'
    log.info '    --short_job     Running time for short jobs (bam indexing and bam2fq)'
    log.info '    --outdir        Directory where resultfiles are stored'
    log.info ''
}

def startup_message() {
    revision = grab_git_revision()

    log.info "======================"
    log.info "WGS-structvar pipeline"
    log.info "======================"
    log.info "Bamfile    : $params.bam"
    log.info "Scriptdir  : $baseDir"
    log.info "Revision   : $revision"
    log.info "Work dir   : $workDir"
    log.info "Output dir : $params.outdir"
    log.info "Project    : $params.project"
    log.info ""
}

def grab_git_revision() {
    if ( workflow.commitId ) { // it's run directly from github
        return workflow.commitId
    }

    // Try to find the revision directly from git
    head_pointer_file = file("${baseDir}/.git/HEAD")
    if ( ! head_pointer_file.exists() ) {
        return ''
    }
    ref = head_pointer_file.newReader().readLine().tokenize()[1]

    ref_file = file("${baseDir}/.git/$ref")
    if ( ! ref_file.exists() ) {
        return ''
    }
    revision = ref_file.newReader().readLine()

    return revision
}

def infer_bam_index_from_bam() {
    // If the ".bam.bai" file does not exist, try ".bai" without ".bam"
    return infer_filepath(params.bam, /$/, '.bai')
        ?: infer_filepath(params.bam, /.bam$/, '.bai')
}

def infer_fastq_from_bam() {
    return infer_filepath(params.bam, /.bam$/, '.fq.gz')
}

def infer_filepath(from, match, replace) {
    path = file( from.replaceAll(match, replace) )
    if (path.exists()) {
        return path
    }
    return false
}

def nextflow_running_as_slurmjob() {
    if ( System.getenv()["SLURM_JOB_ID"] ) {
        return true
    }
    return false
}
