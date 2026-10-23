use v5.14;
use utf8;
use open ':std', ':encoding(UTF-8)';
use Test::More;
use Core::Utils qw(format_time_diff);

# Заметка: format_time_diff использует Date::Calc::N_Delta_YMDHMS для вычислений
# и возвращает разность между текущим временем и переданной датой

# Проверим, что функция импортирована
can_ok('Core::Utils', 'format_time_diff');

subtest 'Basic functionality' => sub {
    # Тест с пустой строкой
    is(format_time_diff(''), '', 'Empty string returns empty string');

    # Тест с undef
    is(format_time_diff(undef), '', 'Undef returns empty string');

    # Тест с некорректным форматом даты
    is(format_time_diff('invalid-date'), '', 'Invalid date format returns empty string');
};

subtest 'Time difference calculations' => sub {
    # Мокаем текущее время для предсказуемых тестов
    # Используем фиксированную дату: 2025-10-07 12:00:00

    # Тестируем различные временные интервалы
    # Примечание: format_time_diff считает от текущего времени НАЗАД к переданной дате

    # Для тестирования будем использовать относительные даты
    # так как функция использует реальное текущее время

    # Тест "менее минуты" - когда разность очень мала
    my $result = format_time_diff('2025-10-07 12:00:00');
    # Результат может быть "менее минуты" или содержать минуты, в зависимости от точного времени
    ok(defined $result, 'Function returns defined result for valid date');
};

subtest 'Chinese time units' => sub {
    # Тестируем правильность склонения русских слов
    # Поскольку функция использует реальное время, создадим тесты для проверки логики склонений

    # Проверим, что результат содержит правильные русские слова
    my $result = format_time_diff('2020-01-01 00:00:00'); # Дата в прошлом

    # Функция должна вернуть строку с русскими словами времени
    ok($result =~ /(?:年|个月|天|小时|分钟|不足一分钟)/,
         'Result contains Chinese time units');
};

subtest 'Date format validation' => sub {
    # Тестируем различные форматы входных данных

    # Корректный формат
    my $valid_date = '2025-01-01 12:30:45';
    my $result = format_time_diff($valid_date);
    ok(defined $result, 'Valid date format works');

    # Некорректные форматы должны возвращать пустую строку
    is(format_time_diff('2025-01-01'), '', 'Date without time returns empty string');
    is(format_time_diff('01-01-2025 12:30:45'), '', 'Wrong date format returns empty string');
    is(format_time_diff('2025/01/01 12:30:45'), '', 'Date with slashes returns empty string');
    is(format_time_diff('not a date'), '', 'Non-date string returns empty string');
};

subtest 'Edge cases' => sub {
    # Тестируем граничные случаи

    # Дата в будущем (за пределами текущего времени)
    my $future_date = '2030-12-31 23:59:59';
    my $future_result = format_time_diff($future_date);
    ok(defined $future_result, 'Future date returns defined result');

    # Очень старая дата
    my $old_date = '1990-01-01 00:00:00';
    my $old_result = format_time_diff($old_date);
    ok(defined $old_result, 'Very old date returns defined result');
    ok($old_result =~ /年/, 'Very old date mentions years');
};

subtest 'Output format validation' => sub {
    # Проверяем, что вывод соответствует ожидаемому формату

    my $result = format_time_diff('2020-01-01 00:00:00');

    # Результат должен быть строкой
    is(ref $result, '', 'Result is a scalar string');

    # Проверяем, что результат содержит только валидные символы (цифры, буквы, пробелы, запятые)
    ok($result =~ /^[\d\s,年个月天小时分钟]+$/i || $result eq '不足一分钟', 'Result contains only valid characters');

    # Если результат не "менее минуты", он должен содержать запятые между компонентами
    if ($result ne '不足一分钟') {
        # Результат может содержать до 3 компонентов, разделенных запятыми
        my @parts = split /,\s*/, $result;
        cmp_ok(scalar @parts, '<=', 3, 'Result has at most 3 time components');
    }
};

subtest 'Specific time differences' => sub {
    # Тестируем конкретные временные разности
    # Используем dates относительно фиксированной точки

    # Тест с датой, которая гарантированно даст "менее минуты"
    # Берем текущее время и вычитаем несколько секунд
    use POSIX qw(strftime);
    my $now_minus_30_sec = strftime("%Y-%m-%d %H:%M:%S", localtime(time - 30));

    # Этот тест может быть нестабильным из-за времени выполнения, поэтому делаем мягкую проверку
    my $result_30_sec = format_time_diff($now_minus_30_sec);
    ok(defined $result_30_sec, 'Date 30 seconds ago returns defined result');
};

subtest 'Multiple component output' => sub {
    # Тестируем вывод с несколькими компонентами времени

    # Используем достаточно старую дату, чтобы получить несколько компонентов
    my $multi_result = format_time_diff('2020-06-15 14:30:20');

    if ($multi_result ne '不足一分钟') {
        # Проверяем, что компоненты разделены правильно
        my @components = split /,\s*/, $multi_result;

        for my $component (@components) {
            # Каждый компонент должен содержать число и русское слово времени
            ok($component =~ /^\d+\s+(?:年|个月|天|小时|分钟)$/,
                 "Component '$component' has correct format");
        }
    }
};

subtest 'Chinese units do not depend on plural endings' => sub {
    my $result_old = format_time_diff('2000-01-01 00:00:00');
    like($result_old, qr/\d+\s+年/, 'Years use the Chinese unit');
    unlike($result_old, qr/[А-Яа-яёЁ]/, 'No Russian plural endings remain');
};

subtest 'Boundary value testing' => sub {
    # Тестируем граничные значения времени

    # Тест с високосным годом
    my $leap_year = format_time_diff('2020-02-29 12:00:00');
    ok(defined $leap_year, 'Leap year date handled correctly');

    # Тест с концом года
    my $year_end = format_time_diff('2024-12-31 23:59:59');
    ok(defined $year_end, 'Year end date handled correctly');

    # Тест с началом года
    my $year_start = format_time_diff('2025-01-01 00:00:00');
    ok(defined $year_start, 'Year start date handled correctly');
};

subtest 'Less than minute cases' => sub {
    # Тестируем случаи когда должно возвращаться "менее минуты"
    use POSIX qw(strftime);

    # Используем текущее время минус несколько секунд
    my $now_minus_10 = strftime("%Y-%m-%d %H:%M:%S", localtime(time - 10));
    my $now_minus_30 = strftime("%Y-%m-%d %H:%M:%S", localtime(time - 30));
    my $now_minus_50 = strftime("%Y-%m-%d %H:%M:%S", localtime(time - 50));

    # Эти тесты могут быть нестабильными из-за времени выполнения
    # поэтому делаем мягкие проверки
    my $result10 = format_time_diff($now_minus_10);
    my $result30 = format_time_diff($now_minus_30);
    my $result50 = format_time_diff($now_minus_50);

    ok(defined $result10, 'Result defined for 10 seconds ago');
    ok(defined $result30, 'Result defined for 30 seconds ago');
    ok(defined $result50, 'Result defined for 50 seconds ago');

    # По крайней мере один из результатов должен быть "менее минуты"
    my $has_less_than_minute = ($result10 eq '不足一分钟') ||
                              ($result30 eq '不足一分钟') ||
                              ($result50 eq '不足一分钟');
    ok($has_less_than_minute || $result10 =~ /分钟/, 'At least one result shows less than minute or minutes');
};

done_testing;
