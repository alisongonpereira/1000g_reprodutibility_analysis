FROM condaforge/miniforge3:24.9.2-0

LABEL org.opencontainers.image.title="1000g-imputation-demo"
LABEL org.opencontainers.image.description="Pinned bcftools/samtools/Beagle/OpenJDK/R environment for the 1000 Genomes imputation reproducibility demo. Built with Docker; the same OCI image also runs unmodified under Apptainer/Singularity on a shared HPC cluster via 'apptainer run docker://...' or 'apptainer pull'."

RUN apt-get update && \
    apt-get install -y --no-install-recommends unzip && \
    rm -rf /var/lib/apt/lists/*

COPY environment.lock.yml /opt/environment.lock.yml
COPY environment.rstats.lock.yml /opt/environment.rstats.lock.yml

# R lives in its own env: its conda-forge build needs icu/libdeflate/gsl
# versions that conflict with the bcftools/samtools/htslib pins above, so
# solving it separately avoids re-pinning the already-verified
# bioinformatics tools just to fit a statistics runtime next to them.
RUN mamba env create -f /opt/environment.lock.yml -n demo && \
    mamba env create -f /opt/environment.rstats.lock.yml -n rstats && \
    mamba clean -afy

ENV PATH="/opt/conda/envs/demo/bin:/opt/conda/envs/rstats/bin:${PATH}"
ENV BEAGLE_JAR="/opt/conda/envs/demo/share/beagle-5.5_27Feb25.75f-0/beagle.jar"

RUN bcftools --version | head -1 && \
    samtools --version | head -1 && \
    java -version && \
    jq --version && \
    unzip -v | head -1 && \
    Rscript --version && \
    test -f "$BEAGLE_JAR"

ENTRYPOINT ["/bin/bash"]
