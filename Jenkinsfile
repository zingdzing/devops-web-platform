pipeline {
  agent any

  options {
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    skipDefaultCheckout(true)
  }

  triggers {
    pollSCM('H/5 * * * *')
  }

  environment {
    CI_FRONTEND_REPOSITORY = 'zingzin/devops-web-platform-frontend'
    CI_BACKEND_REPOSITORY = 'zingzin/devops-web-platform-backend'
  }

  stages {
    stage('Checkout') {
      steps {
        retry(3) {
          checkout scm
          sh 'git fetch --no-tags origin main'
        }
        script {
          sh 'test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"'
          env.GIT_COMMIT_FULL = sh(
            script: 'git rev-parse HEAD',
            returnStdout: true
          ).trim()
          env.GIT_COMMIT_SHORT = env.GIT_COMMIT_FULL.take(12)
          env.IMAGE_TAG = "git-${env.GIT_COMMIT_SHORT}"
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Unit Test') {
      steps {
        sh 'bash scripts/ci/unit-test.sh'
      }
      post {
        always {
          junit testResults: 'reports/pytest.xml', allowEmptyResults: true
        }
      }
    }

    stage('Quality Check') {
      steps {
        sh 'bash scripts/ci/quality-check.sh'
      }
    }

    stage('Build Images') {
      steps {
        sh 'bash scripts/ci/build-images.sh'
      }
    }

    stage('Image Verification') {
      steps {
        sh 'bash scripts/ci/verify-images.sh'
      }
    }

    stage('Push Images') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'dockerhub-ci',
          usernameVariable: 'DOCKERHUB_USERNAME',
          passwordVariable: 'DOCKERHUB_TOKEN'
        )]) {
          script {
            try {
              sh '''
                set +x
                printf '%s' "$DOCKERHUB_TOKEN" \
                  | docker login --username "$DOCKERHUB_USERNAME" --password-stdin
              '''
              retry(3) {
                sh 'docker push "$CI_FRONTEND_REPOSITORY:$IMAGE_TAG"'
              }
              retry(3) {
                sh 'docker push "$CI_BACKEND_REPOSITORY:$IMAGE_TAG"'
              }
            } finally {
              sh 'docker logout >/dev/null 2>&1 || true'
            }
          }
        }
      }
    }

    stage('Deploy') {
      steps {
        withCredentials([file(
          credentialsId: 'k3d-deployer-kubeconfig',
          variable: 'KUBECONFIG'
        )]) {
          sh 'bash scripts/ci/deploy.sh'
        }
      }
    }

    stage('Rollout Verification') {
      steps {
        withCredentials([file(
          credentialsId: 'k3d-deployer-kubeconfig',
          variable: 'KUBECONFIG'
        )]) {
          sh 'bash scripts/ci/deploy.sh --verify-only'
        }
      }
    }

    stage('Smoke Test') {
      steps {
        withCredentials([file(
          credentialsId: 'k3d-deployer-kubeconfig',
          variable: 'KUBECONFIG'
        )]) {
          sh 'bash scripts/ci/smoke-test.sh'
        }
      }
    }
  }

  post {
    always {
      script {
        if (currentBuild.currentResult != 'SUCCESS') {
          try {
            withCredentials([file(
              credentialsId: 'k3d-deployer-kubeconfig',
              variable: 'KUBECONFIG'
            )]) {
              sh 'bash scripts/ci/collect-diagnostics.sh || true'
            }
          } catch (ignored) {
            echo 'Kubernetes credential unavailable; diagnostics skipped.'
          }
        }
      }
      archiveArtifacts artifacts: 'reports/**/*', allowEmptyArchive: true
      sh '''
        rm -r -- .venv-ci 2>/dev/null || true
        if [ -n "${IMAGE_TAG:-}" ]; then
          docker image rm \
            "$CI_FRONTEND_REPOSITORY:$IMAGE_TAG" \
            "$CI_BACKEND_REPOSITORY:$IMAGE_TAG" \
            >/dev/null 2>&1 || true
        fi
      '''
    }
  }
}
