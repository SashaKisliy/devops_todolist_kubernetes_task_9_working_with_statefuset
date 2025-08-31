#!/bin/bash

# Bootstrap script для развертывания ToDo приложения с MySQL StatefulSet в Kubernetes
set -e

echo "🚀 Начинаем развертывание ToDo приложения с MySQL StatefulSet..."

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для логирования
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка наличия необходимых инструментов
check_prerequisites() {
    log_info "Проверка необходимых инструментов..."
    
    if ! command -v kind &> /dev/null; then
        log_error "kind не установлен. Установите kind: https://kind.sigs.k8s.io/docs/user/quick-start/"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl не установлен. Установите kubectl: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        log_error "docker не установлен. Установите Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    log_success "Все необходимые инструменты установлены"
}

# Создание кластера Kind
create_cluster() {
    log_info "Создание кластера Kind..."
    
    if kind get clusters | grep -q "kind"; then
        log_warning "Кластер Kind уже существует"
        read -p "Хотите пересоздать кластер? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Удаление существующего кластера..."
            kind delete cluster
        else
            log_info "Используем существующий кластер"
            return 0
        fi
    fi
    
    log_info "Создание нового кластера из cluster.yml..."
    kind create cluster --config=cluster.yml
    
    # Ждем готовности кластера
    log_info "Ожидание готовности кластера..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_success "Кластер Kind создан и готов"
}

# Сборка Docker образа приложения
build_app_image() {
    log_info "Сборка Docker образа приложения..."
    
    cd src
    docker build -t todoapp:latest .
    cd ..
    
    # Загрузка образа в Kind кластер
    log_info "Загрузка образа в Kind кластер..."
    kind load docker-image todoapp:latest
    
    log_success "Docker образ собран и загружен в кластер"
}

# Развертывание MySQL StatefulSet
deploy_mysql() {
    log_info "Развертывание MySQL StatefulSet..."
    
    # Применяем манифест StatefulSet
    kubectl apply -f statefulSet.yml
    
    # Ждем готовности StatefulSet
    log_info "Ожидание готовности MySQL StatefulSet..."
    kubectl -n mysql rollout status statefulset/mysql --timeout=600s
    
    # Проверяем, что все поды готовы
    kubectl -n mysql wait --for=condition=Ready pod --all --timeout=300s
    
    log_success "MySQL StatefulSet развернут и готов"
}

# Развертывание Django приложения
deploy_app() {
    log_info "Развертывание Django приложения..."
    
    # Применяем манифест Deployment
    kubectl apply -f deployment.yml
    
    # Ждем готовности Deployment
    log_info "Ожидание готовности Django приложения..."
    kubectl -n todoapp rollout status deployment/todoapp --timeout=300s
    
    # Проверяем, что все поды готовы
    kubectl -n todoapp wait --for=condition=Ready pod --all --timeout=300s
    
    log_success "Django приложение развернуто и готово"
}

# Выполнение миграций Django
run_migrations() {
    log_info "Выполнение миграций Django..."
    
    # Получаем имя первого пода приложения
    APP_POD=$(kubectl -n todoapp get pods -l app=todoapp -o jsonpath="{.items[0].metadata.name}")
    
    if [ -z "$APP_POD" ]; then
        log_error "Не найден под приложения для выполнения миграций"
        exit 1
    fi
    
    # Выполняем миграции
    log_info "Выполнение миграций в поде $APP_POD..."
    kubectl -n todoapp exec $APP_POD -- python manage.py migrate
    
    log_success "Миграции выполнены успешно"
}

# Показ статуса развертывания
show_status() {
    log_info "Статус развертывания:"
    
    echo
    echo "=== MySQL StatefulSet ==="
    kubectl -n mysql get statefulset,pods,pvc,svc
    
    echo
    echo "=== Django Application ==="
    kubectl -n todoapp get deployment,pods,svc
    
    echo
    echo "=== Доступ к приложению ==="
    NODE_PORT=$(kubectl -n todoapp get svc todoapp-service -o jsonpath='{.spec.ports[0].nodePort}')
    log_success "Приложение доступно по адресу: http://localhost:$NODE_PORT"
}

# Основная функция
main() {
    echo "=================================="
    echo "  ToDo App с MySQL StatefulSet"
    echo "=================================="
    echo
    
    check_prerequisites
    create_cluster
    build_app_image
    deploy_mysql
    deploy_app
    
    # Небольшая пауза перед выполнением миграций
    log_info "Ожидание стабилизации приложения..."
    sleep 30
    
    run_migrations
    show_status
    
    echo
    log_success "🎉 Развертывание завершено успешно!"
    echo
    echo "Для проверки работы приложения выполните:"
    echo "  kubectl -n todoapp port-forward svc/todoapp-service 8000:8000"
    echo "  Затем откройте http://localhost:8000"
    echo
    echo "Для мониторинга логов:"
    echo "  kubectl -n mysql logs -f statefulset/mysql"
    echo "  kubectl -n todoapp logs -f deployment/todoapp"
}

# Запуск основной функции
main "$@"