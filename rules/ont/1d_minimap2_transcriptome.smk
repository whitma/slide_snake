# Align w/ minimap2
## minimap2 docs - https://lh3.github.io/minimap2/minimap2.html
rule ont_1d_txome_align_minimap2_transcriptome:
    input:
        FQ=lambda w: get_fqs(w, return_type="list", mode="ONT")[1],
    output:
        SAM_TMP=temp("{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/tmp.sam"),
    params:
        EXTRA_FLAGS=lambda wildcards: RECIPE_SHEET["mm2_extra"][wildcards.RECIPE],
        REF=lambda wildcards: SAMPLE_SHEET["cdna_fa"][wildcards.SAMPLE],
    log:
        log="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/minimap2.log",
    resources:
        mem="128G",
    threads: config["CORES"]
    conda:
        f"{workflow.basedir}/envs/minimap2.yml"
    shell:
        """
        mkdir -p $(dirname {output.SAM_TMP})

        echo "Genome reference:   {params.REF}" > {log.log} 
        echo "Junction reference: {params.REF}" >> {log.log} 
        echo "Extra flags:        {params.EXTRA_FLAGS}" >> {log.log} 
        echo "" >> {log.log} 

        minimap2 -ax sr \
            -uf \
            --MD \
            -t {threads} \
            {params.EXTRA_FLAGS} {params.REF} \
            {input.FQ} \
        2>> {log.log} \
        > {output.SAM_TMP}
        """


# Sort and compresss minimap2 output
rule ont_1d_txome_sort_compress_output:
    input:
        SAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/tmp.sam",
    output:
        # BAM_UNSORT_TMP=temp("{OUTDIR}/{SAMPLE}/ont/tmp_unsort.sam"),
        BAM=temp("{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted.bam"),
    params:
        REF=lambda wildcards: SAMPLE_SHEET["cdna_fa"][wildcards.SAMPLE],
    resources:
        mem="16G",
    threads: 1
    shell:
        """
        samtools sort --reference {params.REF} \
            -O BAM \
            -o {output.BAM} \
            {input.SAM}             
        """


# Assign feature (transcript ID) and add gene tag (GN) to each alignment
rule ont_1d_txome_tag_gene:
    input:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted.bam",
        BAI="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted.bam.bai",
    output:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn.bam",
    params:
        TAG="GN",  # corrected barcode tag
    log:
        log="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/tsv2tag_1_GN.log",
    resources:
        mem="32G",
    threads: 1  # long reads can only run single-threaded
    conda:
        f"{workflow.basedir}/envs/minimap2.yml"
    shell:
        """
        bash scripts/bash/bam_chr2tag.sh \
            --input {input.BAM} \
            --output {output.BAM} \
            --tag {params.TAG} \
        |& tee {log.log}
        """


# Add CB to gene-tagged .bam
rule ont_1d_txome_add_corrected_barcodes:
    input:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn.bam",
        TSV="{OUTDIR}/{SAMPLE}/ont/barcodes_umis/{RECIPE}/read_barcodes_corrected.tsv",
    output:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn_cb.bam",
    params:
        READ_ID_COLUMN=0,
        BARCODE_TAG="CB",  # corrected barcode
        BARCODE_TSV_COLUMN=1,
    log:
        log="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/tsv2tag_2_CB.log",
    conda:
        f"{workflow.basedir}/envs/parasail.yml"
    resources:
        mem="16G",
    threads: 1
    shell:
        """
        python scripts/py/tsv2tag.py --in_bam {input.BAM} \
            --in_tsv {input.TSV} \
            --out_bam {output.BAM} \
            --readIDColumn {params.READ_ID_COLUMN} \
            --tagColumns {params.BARCODE_TSV_COLUMN} \
            --tags {params.BARCODE_TAG} \
        |& tee {log.log}
        """


# Add UMI (UR) to barcoded & gene-tagged .bam
rule ont_1d_txome_add_umis:
    input:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn_cb.bam",
        TSV="{OUTDIR}/{SAMPLE}/ont/barcodes_umis/{RECIPE}/read_barcodes_filtered.tsv",
    output:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn_cb_ub.bam",
    params:
        READ_ID_COLUMN=0,
        UMI_TSV_COLUMN=-1,  # last column
        UMI_TAG="UR",  # uncorrected UMI
    log:
        log="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/tsv2tag_3_UR.log",
    conda:
        f"{workflow.basedir}/envs/parasail.yml"
    resources:
        mem="16G",
    threads: 1
    shell:
        """
        python scripts/py/tsv2tag.py --in_bam {input.BAM} \
            --in_tsv {input.TSV} \
            --out_bam {output.BAM} \
            --readIDColumn {params.READ_ID_COLUMN} \
            --tagColumns {params.UMI_TSV_COLUMN} \
            --tags {params.UMI_TAG} \
        |& tee {log.log}
        """


# Generate count matrix w/ umi-tools
rule ont_1d_txome_filter_bam_empty_tags:
    input:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn_cb_ub.bam",
        # BAI="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_gn_cb_ub.bam.bai",
    output:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_filtered_gn_cb_ub.bam",
    params:
        CELL_TAG="CB",  # uncorrected = CR; corrected = CB
        GENE_TAG="GN",  # GN XS
        UMI_TAG="UR",  # uncorrected = UR; corrected = UB
    resources:
        mem="16G",
    threads: 1
    shell:
        """
        samtools view -h {input.BAM} \
        | awk -v tag={params.CELL_TAG} -f scripts/awk/bam_filterEmptyTag.awk \
        | awk -v tag={params.GENE_TAG} -f scripts/awk/bam_filterEmptyTag.awk \
        | awk -v tag={params.UMI_TAG} -f scripts/awk/bam_filterEmptyTag.awk \
        | samtools view -b \
        > {output.BAM}
        """


# Generate count matrix w/ umi-tools
rule ont_1d_txome_umitools_count:
    input:
        BAM="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_filtered_gn_cb_ub.bam",
        BAI="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/sorted_filtered_gn_cb_ub.bam.bai",
    output:
        COUNTS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/umitools_counts.tsv.gz",
    params:
        CELL_TAG="CB",  # uncorrected = CR
        GENE_TAG="GN",  #GN XS
        UMI_TAG="UR",
    log:
        log="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/umitools_count.log",
    resources:
        mem="16G",
    threads: 1
    conda:
        f"{workflow.basedir}/envs/umi_tools.yml"
    shell:
        """
        umi_tools count --extract-umi-method=tag \
            --per-gene \
            --per-cell \
            --cell-tag={params.CELL_TAG} \
            --gene-tag={params.GENE_TAG}  \
            --umi-tag={params.UMI_TAG}  \
            --log={log.log} \
            -I {input.BAM} \
            -S {output.COUNTS} 
        """


# Convert long-format counts from umi_tools to market-matrix format (.mtx)
rule ont_1d_txome_counts_to_sparse:
    input:
        COUNTS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/umitools_counts.tsv.gz",
    output:
        BCS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/barcodes.tsv.gz",
        FEATS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/features.tsv.gz",
        COUNTS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/matrix.mtx.gz",
    resources:
        mem="16G",
    threads: 1
    conda:
        f"{workflow.basedir}/envs/scanpy.yml"
    shell:
        """
        mkdir -p $(dirname {output.COUNTS})
        python scripts/py/long2mtx.py {input.COUNTS} $(dirname {output.COUNTS})
        """


# make anndata object with spatial coordinates
rule ont_1d_txome_cache_preQC_h5ad_minimap2:
    input:
        BCS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/barcodes.tsv.gz",
        FEATS="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/features.tsv.gz",
        MAT="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/matrix.mtx.gz",
        BC_map=lambda w: get_bc_map(w, mode="ONT"),
        # BC_map="{OUTDIR}/{SAMPLE}/bc/map_underscore.txt",
    output:
        H5AD="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/output.h5ad",
    log:
        log="{OUTDIR}/{SAMPLE}/ont/minimap2_txome/{RECIPE}/raw/cache.log",
    threads: 1
    conda:
        f"{workflow.basedir}/envs/scanpy.yml"
    shell:
        """
        python scripts/py/cache_mtx_to_h5ad.py \
            --mat_in {input.MAT} \
            --feat_in {input.FEATS} \
            --bc_in {input.BCS} \
            --bc_map {input.BC_map} \
            --ad_out {output.H5AD} \
            --feat_col 0 \
            --remove_zero_features \
        1> {log.log}
        """
