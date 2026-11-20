// =============================================================================
// Generic CI/CD pipeline — satu Jenkinsfile untuk banyak repository.
//
// Cara kerja:
//   1. Job Jenkins menunjuk ke repo ini (jenkin-ci-cd) dengan "Pipeline script from SCM".
//   2. Parameter PROJECT (default = nama job) memilih file  projects/<PROJECT>.yml
//      yang di-merge di atas projects/_defaults.yml.
//   3. Pipeline meng-clone repository aplikasi ke ./src, menjalankan langkah CI di
//      dalam container (Jenkins tidak perlu Go/Node), build image Docker, kirim image
//      ke server (via registry atau langsung lewat SSH), lalu deploy dengan
//      deploy/deploy.sh + Docker Compose stack di deploy/stacks/<stack>/.
//
// Plugin Jenkins yang dibutuhkan: Pipeline, Git, Credentials Binding, SSH Credentials,
// Pipeline Utility Steps (readYaml), Timestamper.
// =============================================================================

def CFG = [:]
def META = [:]

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {
        string(name: 'PROJECT', defaultValue: env.JOB_BASE_NAME,
               description: 'Nama konfigurasi di projects/<PROJECT>.yml (default: nama job)')
        string(name: 'BRANCH', defaultValue: '',
               description: 'Override branch/tag/commit repository aplikasi (kosong = pakai nilai di config)')
        booleanParam(name: 'RUN_CI', defaultValue: true,
                     description: 'Jalankan langkah test/lint (ci.steps)')
        booleanParam(name: 'DEPLOY', defaultValue: true,
                     description: 'Deploy ke server setelah image berhasil di-build')
    }

    triggers {
        // Cek perubahan repo aplikasi tiap 5 menit. Lebih baik pakai webhook
        // (GitHub → Jenkins) bila server Jenkins bisa diakses dari internet.
        pollSCM('H/5 * * * *')
    }

    stages {
        stage('Load config') {
            steps {
                script {
                    def project = (params.PROJECT ?: env.JOB_BASE_NAME ?: '').trim()
                    if (!(project ==~ /^[A-Za-z0-9._-]+$/)) {
                        error "PROJECT '${project}' tidak valid"
                    }
                    def file = "projects/${project}.yml"
                    if (!fileExists(file)) {
                        error "Konfigurasi ${file} tidak ditemukan. Buat dari projects/_template.yml"
                    }
                    def defaults = fileExists('projects/_defaults.yml') ? readYaml(file: 'projects/_defaults.yml') : [:]
                    CFG = deepMerge(defaults ?: [:], readYaml(file: file) ?: [:])
                    CFG.name = CFG.name ?: project

                    if (!CFG.repo) { error "${file}: 'repo' wajib diisi" }
                    if (!CFG.image?.name) { error "${file}: 'image.name' wajib diisi" }

                    META.project = project
                    META.branch  = (params.BRANCH ?: CFG.branch ?: 'main').trim()
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${project}@${META.branch}"
                    echo "Project : ${project}\nRepo    : ${CFG.repo}\nBranch  : ${META.branch}\nImage   : ${CFG.image.name}"
                }
            }
        }

        stage('Checkout source') {
            steps {
                dir('src') {
                    script {
                        def remote = [url: CFG.repo]
                        if (CFG.git_credentials) { remote.credentialsId = CFG.git_credentials }
                        def ref = META.branch ==~ /^[0-9a-f]{7,40}$/ ? META.branch : "*/${META.branch}"
                        checkout([
                            $class           : 'GitSCM',
                            branches         : [[name: ref]],
                            userRemoteConfigs: [remote],
                            extensions       : [
                                [$class: 'CloneOption', shallow: true, depth: 50, noTags: false, timeout: 20],
                                [$class: 'CleanBeforeCheckout'],
                                [$class: 'SubmoduleOption', recursiveSubmodules: true, parentCredentials: true, shallow: true],
                            ],
                        ])
                        META.commit = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                        META.short  = META.commit.substring(0, 8)
                        META.tag    = "${env.BUILD_NUMBER}-${META.short}"
                        currentBuild.description = "${META.short}"
                    }
                }
            }
        }

        stage('CI (test / lint)') {
            when { expression { params.RUN_CI && (CFG.ci?.steps ?: []).size() > 0 } }
            steps {
                script {
                    def cache = "${env.JENKINS_HOME ?: env.HOME}/ci-cache/${META.project}"
                    sh "mkdir -p '${cache}/home' .ci"
                    def ciSteps = CFG.ci.steps
                    for (int i = 0; i < ciSteps.size(); i++) {
                        def st = ciSteps[i]
                        def label = st.name ?: "step-${i + 1}"
                        stage("CI: ${label}") {
                            writeFile file: ".ci/step-${i}.sh", text: "set -eu\n${st.run}\n"
                            def workdir = st.workdir ?: CFG.ci.workdir ?: '.'
                            def envMap = deepMerge(CFG.ci.env ?: [:], st.env ?: [:])
                            def envFlags = envArgs(envMap)
                            def image = st.image ?: CFG.ci.image
                            if (image) {
                                // Jalankan di container dengan UID jenkins, workspace + cache di-mount.
                                sh """
                                    docker run --rm \\
                                      -u "\$(id -u):\$(id -g)" \\
                                      -v "\$PWD/src:/workspace" \\
                                      -v "\$PWD/.ci:/ci:ro" \\
                                      -v '${cache}:/cache' \\
                                      -e HOME=/cache/home \\
                                      -e GOPATH=/cache/go -e GOCACHE=/cache/go-build \\
                                      -e npm_config_cache=/cache/npm -e YARN_CACHE_FOLDER=/cache/yarn \\
                                      -e PIP_CACHE_DIR=/cache/pip -e CI=true \\
                                      ${envFlags} \\
                                      -w ${shq('/workspace/' + workdir)} \\
                                      ${shq(image)} sh /ci/step-${i}.sh
                                """
                            } else {
                                // Tanpa image: jalan langsung di host Jenkins (tool harus terpasang).
                                dir("src/${workdir}") {
                                    withEnv(envList(envMap)) {
                                        sh "sh ${env.WORKSPACE}/.ci/step-${i}.sh"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        stage('Build image') {
            steps {
                script {
                    def b = CFG.build ?: [:]
                    def context = "src/${b.context ?: '.'}"
                    def dockerfile

                    if (b.template) {
                        // Repo tidak punya Dockerfile → pakai template dari templates/<nama>/
                        if (!fileExists("templates/${b.template}/Dockerfile")) {
                            error "Template templates/${b.template} tidak ditemukan"
                        }
                        sh """
                            rm -rf '${context}/.ci-template'
                            cp -R 'templates/${b.template}' '${context}/.ci-template'
                            if [ ! -f '${context}/.dockerignore' ] && [ -f '${context}/.ci-template/dockerignore' ]; then
                                cp '${context}/.ci-template/dockerignore' '${context}/.dockerignore'
                            fi
                        """
                        dockerfile = "${context}/.ci-template/Dockerfile"
                    } else {
                        dockerfile = "${context}/${b.dockerfile ?: 'Dockerfile'}"
                    }

                    // Variabel build-time untuk frontend (Vite/CRA/Vue CLI membaca .env.production.local)
                    if (b.env_file && b.env) {
                        writeFile file: "${context}/${b.env_file}", text: envList(b.env).join('\n') + '\n'
                    }

                    META.imageRepo = imageRepo(CFG, null)
                    def buildCmd = { String repo ->
                        def args = buildArgs(b.args ?: [:])
                        def platform = b.platform ? "--platform ${shq(b.platform)}" : ''
                        def target = b.target ? "--target ${shq(b.target)}" : ''
                        sh """
                            docker build --pull ${platform} ${target} \\
                              -f '${dockerfile}' \\
                              -t '${repo}:${META.tag}' -t '${repo}:latest' \\
                              --label org.opencontainers.image.source=${shq(CFG.repo)} \\
                              --label org.opencontainers.image.revision=${META.commit} \\
                              --label ci.build=${env.BUILD_NUMBER} \\
                              ${args} '${context}'
                        """
                    }

                    if (pushMode(CFG) == 'registry') {
                        withRegistry(CFG) { user ->
                            META.imageRepo = imageRepo(CFG, user)
                            buildCmd(META.imageRepo)
                            sh "docker push '${META.imageRepo}:${META.tag}'"
                            if (CFG.registry?.push_latest) { sh "docker push '${META.imageRepo}:latest'" }
                        }
                    } else {
                        buildCmd(META.imageRepo)
                    }
                    META.image = "${META.imageRepo}:${META.tag}"
                    echo "Image siap: ${META.image}"
                }
            }
        }

        stage('Deploy') {
            when { expression { params.DEPLOY && CFG.deploy?.enabled != false && CFG.deploy?.stack } }
            steps {
                script {
                    def d = CFG.deploy
                    def stackDir = "deploy/stacks/${d.stack}"
                    if (!fileExists("${stackDir}/docker-compose.yml")) {
                        error "Stack ${stackDir}/docker-compose.yml tidak ditemukan"
                    }
                    def remoteDir = "${d.base_dir ?: '/opt/apps'}/${d.stack}"
                    def service = d.service ?: CFG.name
                    def imageVar = d.image_var ?: (service.toUpperCase().replaceAll(/[^A-Z0-9]/, '_') + '_IMAGE')

                    // File rilis: dibaca oleh deploy.sh di server.
                    writeFile file: '.ci/release.env', text: [
                        "SERVICE=${shq(service)}",
                        "IMAGE_VAR=${shq(imageVar)}",
                        "IMAGE=${shq(META.image)}",
                        "PULL=${pushMode(CFG) == 'registry' ? 'true' : 'false'}",
                        "HEALTH_CMD=${shq(d.health?.cmd ?: '')}",
                        "HEALTH_RETRIES=${shq((d.health?.retries ?: 30).toString())}",
                        "HEALTH_INTERVAL=${shq((d.health?.interval ?: 5).toString())}",
                        "ROLLBACK=${d.rollback == false ? 'false' : 'true'}",
                        "COMMIT=${shq(META.commit)}",
                        "BUILD=${shq(env.BUILD_TAG ?: env.BUILD_NUMBER)}",
                    ].join('\n') + '\n'

                    withDeployTarget(d) { String ssh, String scpTarget ->
                        sh """
                            set -eu
                            ${ssh} "mkdir -p ${remoteDir}/.release"
                            # Salin file stack (compose, hooks, dll) + deploy.sh. File .env di server TIDAK disentuh.
                            tar -C '${stackDir}' --exclude='.env' -cf - . | ${ssh} "tar -C ${remoteDir} -xf -"
                            cat deploy/deploy.sh | ${ssh} "cat > ${remoteDir}/deploy.sh && chmod 755 ${remoteDir}/deploy.sh"
                            cat .ci/release.env  | ${ssh} "cat > ${remoteDir}/.release/${service}.env"
                        """
                        if (pushMode(CFG) == 'registry') {
                            withRegistry(CFG) { user ->
                                sh """
                                    set -eu
                                    printf '%s' "\$REGISTRY_PASS" | ${ssh} "docker login ${shq(registryHost(CFG))} -u '\$REGISTRY_USER' --password-stdin" >/dev/null
                                    ${ssh} "cd ${remoteDir} && ./deploy.sh ${shq(service)}; rc=\\\$?; docker logout ${shq(registryHost(CFG))} >/dev/null 2>&1; exit \\\$rc"
                                """
                            }
                        } else {
                            // Tanpa registry: stream image langsung ke server.
                            sh """
                                set -eu
                                docker save '${META.image}' | gzip -1 | ${ssh} "gunzip | docker load"
                                ${ssh} "cd ${remoteDir} && ./deploy.sh ${shq(service)}"
                            """
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            echo "✅ ${META.project} ${META.image ?: ''} selesai."
        }
        failure {
            echo "❌ Pipeline ${META.project ?: ''} gagal. Cek log stage di atas."
        }
        always {
            script {
                if (META.image && pushMode(CFG) == 'registry') {
                    // Tag "latest" dipertahankan sebagai cache build berikutnya.
                    sh "docker image rm '${META.image}' >/dev/null 2>&1 || true"
                }
            }
            sh 'docker image prune -f >/dev/null 2>&1 || true'
            sh 'rm -f .ci/release.env || true'
        }
    }
}

// ----------------------------------------------------------------------------- helpers

@NonCPS
def deepMerge(Map base, Map over) {
    def out = [:]
    base.each { k, v -> out[k] = v }
    over.each { k, v ->
        if (v instanceof Map && out[k] instanceof Map) {
            out[k] = deepMerge(out[k] as Map, v as Map)
        } else {
            out[k] = v
        }
    }
    return out
}

/** Single-quote untuk shell. */
@NonCPS
def shq(Object s) {
    return "'" + (s == null ? '' : s.toString()).replace("'", "'\"'\"'") + "'"
}

@NonCPS
def envArgs(Map m) {
    return m.collect { k, v -> "-e ${shq(k + '=' + (v == null ? '' : v))}" }.join(' ')
}

@NonCPS
def envList(Map m) {
    return m.collect { k, v -> "${k}=${v == null ? '' : v}".toString() }
}

@NonCPS
def buildArgs(Map m) {
    return m.collect { k, v -> "--build-arg ${shq(k + '=' + (v == null ? '' : v))}" }.join(' ')
}

@NonCPS
def pushMode(Map cfg) {
    return (cfg.registry?.mode ?: 'registry').toString()
}

@NonCPS
def registryHost(Map cfg) {
    return (cfg.registry?.url ?: 'docker.io').toString()
}

/** <registry>/<namespace>/<image> — namespace default = username registry. */
@NonCPS
def imageRepo(Map cfg, String user) {
    def name = cfg.image.name.toString()
    if (pushMode(cfg) != 'registry') {
        return cfg.image.local_prefix ? "${cfg.image.local_prefix}/${name}" : name
    }
    def ns = cfg.registry?.namespace ?: user
    return [registryHost(cfg), ns, name].findAll { it }.join('/').toLowerCase()
}

/** docker login di agent Jenkins; REGISTRY_USER / REGISTRY_PASS tersedia di dalam body. */
def withRegistry(Map cfg, Closure body) {
    def credId = cfg.registry?.credentials
    if (!credId) { error "registry.credentials belum diisi (atau set registry.mode: ssh)" }
    withCredentials([usernamePassword(credentialsId: credId, usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASS')]) {
        sh "printf '%s' \"\$REGISTRY_PASS\" | docker login ${shq(registryHost(cfg))} -u \"\$REGISTRY_USER\" --password-stdin >/dev/null"
        try {
            body(env.REGISTRY_USER)
        } finally {
            sh "docker logout ${shq(registryHost(cfg))} >/dev/null 2>&1 || true"
        }
    }
}

/**
 * Menyediakan perintah ssh siap pakai ke server tujuan.
 * Host bisa literal (deploy.host) atau dari credential Secret text (deploy.host_credentials).
 */
def withDeployTarget(Map d, Closure body) {
    def creds = [sshUserPrivateKey(credentialsId: d.ssh_credentials ?: 'app-server-ssh',
                                   keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]
    if (!d.host) {
        creds << string(credentialsId: d.host_credentials ?: 'app-server-host', variable: 'DEPLOY_HOST')
    }
    withCredentials(creds) {
        // Host/user dari credential TIDAK diinterpolasi Groovy (tetap jadi variabel shell yang di-mask).
        // Hanya nilai literal dari config (bukan secret) yang dimasukkan lewat withEnv.
        def extra = ["DEPLOY_PORT=${(d.ssh_port ?: 22).toString()}"]
        if (d.host) { extra << "DEPLOY_HOST=${d.host}" }
        def userVar = d.user ? 'DEPLOY_USER' : 'SSH_USER'
        if (d.user) { extra << "DEPLOY_USER=${d.user}" }
        withEnv(extra) {
            def opts = '-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o BatchMode=yes'
            def target = "\$${userVar}@\$DEPLOY_HOST"
            def ssh = "ssh -i \"\$SSH_KEY\" -p \"\$DEPLOY_PORT\" ${opts} \"${target}\""
            body(ssh, target)
        }
    }
}
