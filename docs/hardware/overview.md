# Arquitetura e Design

!!! abstract "Dataflow: Output-Stationary"
    O design implementa uma arquitetura **Output-Stationary**. Dessa forma, as somas parciais (*partial sums*) são acumuladas localmente nos *Processing Elements* (PEs), levando a uma redução drástica na largura de banda necessária para escrever os resultados intermediários de volta na memória.

!!! abstract "Princípio da Localidade"
    Essa abordagem aproveita o princípio da localidade, que é garantido pelas **memórias locais (*scratchpads*)** da NPU, para maximizar o reuso de dados internos. 